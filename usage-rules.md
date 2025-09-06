# Otto Usage Rules

## Otto Project Structure

Otto is an Elixir umbrella application designed for home improvement project management with AI agent assistance.

### Core Components

1. **OttoLive** - Phoenix LiveView web application
   - Main user interface 
   - Real-time updates via LiveView
   - PostgreSQL for data persistence
   - Tidewave integration for AI assistance

2. **Otto.Manager** - Project management engine
   - Supervised application for managing home improvement projects
   - Handles project lifecycle, scheduling, resource allocation

3. **Otto.Agent** - AI agent system
   - Supervised application for AI-powered assistance
   - Integrates with external AI services
   - Provides contextual help and automation

### Development Patterns

#### Starting Development
```bash
mix phx.server                    # Start all applications
iex -S mix phx.server            # Start with IEx console
mix test                         # Run all tests
```

#### Database Operations
```bash
mix ecto.setup                   # Create, migrate, and seed
mix ecto.create                  # Create database
mix ecto.migrate                 # Run migrations
mix ecto.reset                   # Drop and recreate
```

#### AI Tools Integration
- Access Tidewave at `/tidewave` for AI-powered development
- Use LiveDashboard at `/dashboard` for runtime insights
- Usage rules are synced automatically for dependency guidance

### Code Organization

#### Phoenix LiveView App (`apps/otto_live`)
- Controllers: `lib/otto_live_web/controllers/`
- LiveViews: `lib/otto_live_web/live/`
- Components: `lib/otto_live_web/components/`
- Contexts: `lib/otto_live/`

#### Manager App (`apps/otto_manager`)
- Main module: `lib/otto/manager.ex`
- Application: `lib/otto/manager/application.ex`

#### Agent App (`apps/otto_agent`)
- Main module: `lib/otto/agent.ex`
- Application: `lib/otto/agent/application.ex`

### Best Practices

1. **Umbrella Structure**: Each app is self-contained with its own dependencies
2. **Supervision**: Use OTP principles, each app has proper supervision trees
3. **LiveView**: Prefer LiveView over traditional controllers for interactive features
4. **AI Integration**: Leverage Tidewave for development, agents for user assistance
5. **Testing**: Test each app independently, integration tests for cross-app communication

### Configuration

- Development: `config/dev.exs`
- Test: `config/test.exs`
- Production: `config/prod.exs` and `config/runtime.exs`
- App-specific configs in respective app directories

### Common Tasks

```bash
# Update usage rules from dependencies
mix usage_rules.update

# Search dependency documentation
mix usage_rules.search_docs "search term"

# Format all code
mix format

# Run static analysis
mix credo

# Generate documentation
mix docs
```