#!/bin/bash

set -euo pipefail

# Get script directory and sim path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_DIR="$SCRIPT_DIR/sim"

# Flags
BUILD=false
LOCAL=true ## remove before prod
# LOCAL=false ## add before prod
CMD_UP=false
CMD_DOWN=false

# Help function
show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Start Sim Studio with Docker containers

Options:
  -h, --help     Show this help message
  -b, --build        Build containers required to run the application
  -u, --up           Start the compose cluster
  -d, --down         Stop the compose cluster
  -l, --local        Use local LLM configuration with Ollama service
EOF
    exit 0
}

boot_db() {
  # Load .env vars
  set -a
  source "$SIM_DIR/.env"
  set +a

  echo "⏳ Waiting for PostgreSQL to be ready at $PG_HOST:$PG_PORT..."

  RETRIES=20
  until docker compose exec -T simcity pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" >/dev/null 2>&1 || [ "$RETRIES" -eq 0 ]; do
      echo "Waiting... ($RETRIES retries left)"
      RETRIES=$((RETRIES - 1))
      sleep 2
  done

  if [ "$RETRIES" -eq 0 ]; then
      echo "⚠️ pg_isready failed — trying Prisma fallback..."
      RETRIES=10
      until docker compose exec -T simcity npx prisma db pull >/dev/null 2>&1 || [ "$RETRIES" -eq 0 ]; do
          echo "Fallback waiting... ($RETRIES retries left)"
          RETRIES=$((RETRIES - 1))
          sleep 2
      done

      if [ "$RETRIES" -eq 0 ]; then
          echo "❌ Database never became ready. Aborting."
          exit 1
      fi
  fi

  echo "✅ Database is ready."
  sleep 1
  echo "🔧 Running database migrations..."
  docker compose exec simcity npm run db:push
}

# Parse args
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help ;;
        -b|--build)   BUILD=true ;;
        -l|--local)   LOCAL=true ;;
        -u|--up)      CMD_UP=true ;;
        -d|--down)    CMD_DOWN=true ;;
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
    export COMPOSE_BAKE=true

    if [ ! -f "$SIM_DIR/.env" ]; then
        cp "$SIM_DIR/.env.example" "$SIM_DIR/.env"

        # Generate two separate secure keys
        AUTH_KEY=$(./scripts/generate_hex_key.sh)
        ENC_KEY=$(./scripts/generate_hex_key.sh)

        {
            echo ""
            echo "# 🔐 Auto-generated secrets"
            echo "BETTER_AUTH_SECRET=$AUTH_KEY"
            echo "ENCRYPTION_KEY=$ENC_KEY"
        } >> "$SIM_DIR/.env"

        echo ".env file created with generated secrets. Please update it with any additional configuration."
    else
        echo ".env file found."
    fi

    mkdir -p "$SIM_DIR/data"

    echo
    echo "🔧 Building Docker containers..."
    docker compose build
    
    echo
    echo "📚 Running doc generator setup..."
    ./scripts/setup-doc-generator.sh
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
    
    echo "🚀 Cluster is up. Tail logs below:"
    sleep 3
    docker compose logs -f 
fi

