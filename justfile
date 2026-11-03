# Maat — every build, test, lint, and run command goes through just.

set shell := ["bash", "-uc"]

# List all commands
default:
    @just --list

# Install Hex and Rebar, then fetch dependencies
setup:
    mix local.hex --force
    mix local.rebar --force
    mix deps.get

# Compile the project
compile:
    mix compile

# Run the test suite; pass extra args after the recipe name, e.g. just test test/engine
test *args:
    mix test {{args}}

# Run only the property-based (StreamData) suites
test-property:
    mix test --only property

# Format the code
fmt:
    mix format

# Check formatting, then fail on compiler warnings
lint:
    mix format --check-formatted
    mix compile --warnings-as-errors

# Run the application; pass extra args after the recipe name
run *args:
    mix run {{args}}

# Start the API server in the foreground
serve:
    mix run --no-halt

# Start the human UI (requires the maat_ui package from milestone M4)
ui:
    cd maat_ui && mix phx.server

# Remove build artifacts
clean:
    mix clean
    rm -rf _build

# Lint, then test
check: lint test

# Print the agent documentation
docs:
    @cat AGENTS.md ARCHITECTURE.md STATUS.md DECISIONS.md
