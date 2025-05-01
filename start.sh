#!/bin/bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SIM_DIR=$SCRIPT_DIR/sim

# Function to display help
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Start Sim Studio with Docker containers"
    echo
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  --local        Use local LLM configuration with Ollama service"
    echo "  --build        Build containers required to run the application"
    echo
    echo "Examples:"
    echo "  $0              # Start without local LLM"
    echo "  $0 --local      # Start with local LLM (requires GPU)"
    echo
    echo "Note: When using --local flag, GPU availability is automatically detected"
    echo "      and appropriate configuration is used."
    exit 0
}

# Parse command line arguments
LOCAL=false
BUILD=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) show_help ;;
        --local) LOCAL=true ;;
        --build) BUILD=true ;;
        *) echo "Unknown parameter: $1"; echo "Use -h or --help for usage information"; exit 1 ;;
    esac
    shift
done

if [ ! -f $SIM_DIR/.env ]; then
  if [ "$BUILD" = true ]; then
    cp $SIM_DIR/.env.example $SIM_DIR/.env
    echo ".env file created. Please update it with your configuration."
  else
    echo ".env file not found! Please restart this application with flag --build, then try again."
    sleep 5
    exit
  fi
else
  echo ".env file found."
fi

# Build containers
if [ "$BUILD" = true ]; then
    docker compose build 
fi

# Stop any running containers
docker compose down

# Start containers
if [ "$LOCAL" = true ]; then
    docker compose --profile local-cpu up -d
else
    docker compose up -d
fi

# Wait for database to be ready
echo "Waiting for database to be ready..."
sleep 5

# Apply migrations automatically
echo "Applying database migrations..."
docker compose exec simcity npm run db:push

./scripts/setup-doc-generator.sh

docker compose logs -f simcity
