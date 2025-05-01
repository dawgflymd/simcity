#!/bin/bash
set -euo pipefail

# Get script directory and sim path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_DIR="$SCRIPT_DIR/sim"

# Flags
BUILD=false
LOCAL=false
CMD_UP=false
CMD_DOWN=false

# Help function
show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Start Sim Studio with Docker containers

Options:
  -h, --help     Show this help message
  --build        Build containers required to run the application
  --up           Start the compose cluster
  --down         Stop the compose cluster
  --local        Use local LLM configuration with Ollama service
EOF
    exit 0
}

# Parse args
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help ;;
        --build)   BUILD=true ;;
        --local)   LOCAL=true ;;
        --up)      CMD_UP=true ;;
        --down)    CMD_DOWN=true ;;
        *) echo "❌ Unknown parameter: $1"; echo "Use -h or --help for usage information"; exit 1 ;;
    esac
    shift
done

# Validate at least one action
if ! $BUILD && ! $CMD_UP && ! $CMD_DOWN && ! $LOCAL; then
    echo
    echo " ❌| You forgot to pass in a flag!"
    echo
    exit 1
fi

# Build containers
if $BUILD; then
    if [ ! -f "$SIM_DIR/.env" ]; then
        cp "$SIM_DIR/.env.example" "$SIM_DIR/.env"
        echo ".env file created. Please update it with your configuration."
    else
        echo ".env file found."
    fi
    mkdir -p $SIM_DIR/data
    docker compose build
fi

# Stop containers
if $CMD_DOWN; then
    docker compose down
    docker system prune -f
    docker volume prune -f
    echo "🛑 Cluster stopped."
    exit 0
fi

# Start containers
if $CMD_UP; then
    docker compose down
    if $LOCAL; then
        docker compose --profile local-cpu up -d
    else
        docker compose up -d
    fi
    
    RETRIES=5
    echo "⏳ Waiting for database to be ready..."
    
    until docker compose exec -T simcity npx prisma db pull >/dev/null 2>&1 || [ "$RETRIES" -eq 0 ]; do
        echo "Waiting... ($RETRIES retries left)"
        RETRIES=$((RETRIES - 1))
        sleep 2
    done

    if [ "$RETRIES" -eq 0 ]; then
        echo "❌ Database did not become ready in time."
        exit 1
    fi

    echo "✅ Database is ready."

    echo "🔧 Running database migrations..."
    docker compose exec simcity npm run db:push
    
    ./scripts/setup-doc-generator.sh 

    echo "🚀 Cluster is up. Tail logs below:"
    sleep 3
    docker compose logs -f simcity
fi

