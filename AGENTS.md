# Otto Project Usage Rules

**IMPORTANT**: Consult these usage rules early and often when working with the Otto umbrella project.
These rules contain guidelines and patterns for working with Otto's components and dependencies.

## Otto Project Structure

Otto is an Elixir umbrella application with three main components:

### OttoLive (`apps/otto_live`)
- Phoenix LiveView web application with PostgreSQL support
- Main web interface at http://localhost:4000
- Tidewave AI assistance available at http://localhost:4000/tidewave
- LiveDashboard available at http://localhost:4000/dashboard

### Otto.Manager (`apps/otto_manager`) 
- Supervised Elixir application for project management tasks
- Has its own application supervisor at `Otto.Manager.Application`

### Otto.Agent (`apps/otto_agent`)
- Supervised Elixir application for agent functionality
- Has its own application supervisor at `Otto.Agent.Application`

## Development Guidelines

### Database
- PostgreSQL database configured as "otto_live_dev" 
- Use `OttoLive.Repo` for database operations
- Database accessible via `mix ecto.create`, `mix ecto.migrate`

### AI Development Tools
- **Tidewave**: AI-powered coding assistant integrated at `/tidewave`
  - Point-and-click UI element selection
  - Runtime introspection and code evaluation
  - MCP protocol support at `http://localhost:4000/tidewave/mcp`
- **Usage Rules**: LLM guidance system for dependencies
  - Use `mix usage_rules.search_docs` to search documentation
  - Use `mix usage_rules.update` to sync dependency rules

### Starting the Application
```bash
# Start the Phoenix server
mix phx.server

# Or with IEx
iex -S mix phx.server
```

### Code Conventions
- Follow Elixir/Phoenix standard patterns
- Use LiveView for interactive UI components
- Keep business logic in contexts, not controllers
- Use Ecto changesets for data validation
- Each app maintains its own supervision tree

### Umbrella App Structure
- Root `mix.exs` contains only development dependencies
- Each app has its own dependencies in their respective `mix.exs`
- Shared config in `/config` directory
- Each app can be developed and tested independently

## Framework-Specific Rules

### Phoenix LiveView
- Use `debug_heex_annotations: true` for development
- Components in `lib/otto_live_web/components/`
- Live views in `lib/otto_live_web/live/`
- Follow Phoenix 1.8+ patterns

### Ecto
- Schemas in `lib/otto_live/` namespace
- Migrations in `priv/repo/migrations/`
- Use changeset functions for validation
- Prefer Repo transactions for multi-step operations

### Supervision
- Each Otto app has its own application module
- Use standard OTP supervision patterns
- Child specs in respective application modules