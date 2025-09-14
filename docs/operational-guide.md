# Otto Operational Guide

This guide covers deploying, monitoring, and maintaining Otto in production environments. It includes performance tuning, scaling strategies, troubleshooting, and operational best practices.

## Table of Contents

1. [Production Deployment](#production-deployment)
2. [Monitoring & Observability](#monitoring--observability)
3. [Performance Tuning](#performance-tuning)
4. [Scaling Strategies](#scaling-strategies)
5. [Security Hardening](#security-hardening)
6. [Backup & Recovery](#backup--recovery)
7. [Troubleshooting](#troubleshooting)
8. [Maintenance Procedures](#maintenance-procedures)
9. [Capacity Planning](#capacity-planning)
10. [SLA Management](#sla-management)

## Production Deployment

### System Requirements

#### Minimum Requirements
- **CPU**: 2 cores (4+ recommended)
- **RAM**: 4GB (8GB+ recommended)
- **Disk**: 20GB SSD (100GB+ for production)
- **Network**: Reliable internet connection
- **OS**: Ubuntu 20.04+ / CentOS 8+ / Docker

#### Recommended Production Specs
- **CPU**: 8+ cores for high concurrency
- **RAM**: 16GB+ with swap disabled
- **Disk**: NVMe SSD with 1000+ IOPS
- **Network**: Dedicated connection with monitoring
- **Load Balancer**: HAProxy/nginx for multi-instance deployments

### Docker Deployment

#### Dockerfile

```dockerfile
FROM elixir:1.15-alpine AS builder

# Install build dependencies
RUN apk add --no-cache build-base git

# Set build ENV
ENV MIX_ENV=prod

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Create app directory
WORKDIR /app

# Copy mix files
COPY mix.exs mix.lock ./
COPY apps/*/mix.exs apps/*/

# Install dependencies
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy application files
COPY . .

# Compile and build release
RUN mix compile
RUN mix release

# Runtime stage
FROM alpine:3.18

# Install runtime dependencies
RUN apk add --no-cache \
    openssl \
    ncurses-libs \
    ripgrep \
    curl

# Create user
RUN addgroup -g 1001 otto && \
    adduser -D -s /bin/sh -u 1001 -G otto otto

# Create directories
RUN mkdir -p /app/var/otto/sessions /app/var/logs && \
    chown -R otto:otto /app

USER otto
WORKDIR /app

# Copy release
COPY --from=builder --chown=otto:otto /app/_build/prod/rel/otto ./

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:4000/health || exit 1

# Expose port
EXPOSE 4000

CMD ["bin/otto", "start"]
```

#### Docker Compose

```yaml
version: '3.8'

services:
  otto:
    build: .
    ports:
      - "4000:4000"
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - DATABASE_URL=${DATABASE_URL}
      - OTTO_CHECKPOINT_DIR=/app/var/otto/sessions
      - OTTO_LOG_LEVEL=info
      - OTTO_MAX_CONCURRENT_AGENTS=50
    volumes:
      - otto_data:/app/var
      - otto_logs:/app/var/logs
      - ./config/production.yml:/app/.otto/environments/production.yml:ro
    depends_on:
      - postgres
      - redis
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "100m"
        max-file: "5"

  postgres:
    image: postgres:15
    environment:
      - POSTGRES_DB=otto_prod
      - POSTGRES_USER=otto
      - POSTGRES_PASSWORD=${DB_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    volumes:
      - redis_data:/data
    restart: unless-stopped

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./config/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/ssl/certs:ro
    depends_on:
      - otto
    restart: unless-stopped

volumes:
  otto_data:
  otto_logs:
  postgres_data:
  redis_data:
```

### Kubernetes Deployment

#### Namespace and ConfigMap

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: otto-system
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otto-config
  namespace: otto-system
data:
  production.yml: |
    # Otto production configuration
    checkpoint_enabled: true
    checkpoint_dir: /app/var/otto/sessions
    log_level: info
    max_concurrent_agents: 100

    budgets:
      default_time_seconds: 300
      default_tokens: 10000
      default_cost_cents: 100
      max_daily_cost_cents: 10000
---
apiVersion: v1
kind: Secret
metadata:
  name: otto-secrets
  namespace: otto-system
type: Opaque
stringData:
  anthropic-api-key: "your-api-key-here"
  database-url: "postgresql://user:pass@postgres:5432/otto_prod"
```

#### Deployment and Service

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otto
  namespace: otto-system
spec:
  replicas: 3
  selector:
    matchLabels:
      app: otto
  template:
    metadata:
      labels:
        app: otto
    spec:
      containers:
      - name: otto
        image: your-registry/otto:v1.0.0
        ports:
        - containerPort: 4000
        env:
        - name: ANTHROPIC_API_KEY
          valueFrom:
            secretKeyRef:
              name: otto-secrets
              key: anthropic-api-key
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: otto-secrets
              key: database-url
        - name: OTTO_CHECKPOINT_DIR
          value: /app/var/otto/sessions
        - name: OTTO_MAX_CONCURRENT_AGENTS
          value: "100"
        volumeMounts:
        - name: otto-data
          mountPath: /app/var
        - name: otto-config
          mountPath: /app/.otto/environments
        resources:
          requests:
            memory: "2Gi"
            cpu: "1000m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
        livenessProbe:
          httpGet:
            path: /health
            port: 4000
          initialDelaySeconds: 60
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 4000
          initialDelaySeconds: 15
          periodSeconds: 10
      volumes:
      - name: otto-data
        persistentVolumeClaim:
          claimName: otto-data-pvc
      - name: otto-config
        configMap:
          name: otto-config
---
apiVersion: v1
kind: Service
metadata:
  name: otto-service
  namespace: otto-system
spec:
  selector:
    app: otto
  ports:
    - protocol: TCP
      port: 80
      targetPort: 4000
  type: LoadBalancer
```

### Environment Configuration

#### Production Environment Variables

```bash
# Application
OTTO_ENV=production
OTTO_ENABLED=true
SECRET_KEY_BASE=your-secret-key-here

# Database
DATABASE_URL=postgresql://user:pass@db-host:5432/otto_prod
DATABASE_POOL_SIZE=20

# LLM Provider
ANTHROPIC_API_KEY=your-api-key-here

# Otto Configuration
OTTO_CHECKPOINT_DIR=/app/var/otto/sessions
OTTO_LOG_LEVEL=info
OTTO_MAX_CONCURRENT_AGENTS=100
OTTO_DEFAULT_BUDGET_CENTS=100
OTTO_MAX_DAILY_COST_CENTS=50000
OTTO_KILL_SWITCH=false

# Monitoring
TELEMETRY_ENABLED=true
PROMETHEUS_PORT=9090
SENTRY_DSN=your-sentry-dsn

# Security
SANDBOX_ENABLED=true
CORS_ALLOWED_ORIGINS=https://your-domain.com
```

## Monitoring & Observability

### Telemetry Setup

Otto emits comprehensive telemetry events for monitoring:

```elixir
# lib/otto/telemetry.ex
defmodule Otto.Telemetry do
  def setup do
    events = [
      # Agent events
      [:otto, :agent, :started],
      [:otto, :agent, :completed],
      [:otto, :agent, :failed],
      [:otto, :agent, :timeout],

      # Tool events
      [:otto, :tool, :called],
      [:otto, :tool, :completed],
      [:otto, :tool, :failed],

      # Budget events
      [:otto, :budget, :warning],
      [:otto, :budget, :exceeded],

      # System events
      [:otto, :system, :health_check],
      [:otto, :system, :error]
    ]

    :telemetry.attach_many(
      "otto-monitoring",
      events,
      &handle_event/4,
      %{}
    )
  end

  defp handle_event(event, measurements, metadata, _config) do
    # Send to Prometheus
    emit_prometheus_metrics(event, measurements, metadata)

    # Send to logging system
    emit_structured_logs(event, measurements, metadata)

    # Send alerts for critical events
    maybe_send_alert(event, measurements, metadata)
  end
end
```

### Prometheus Metrics

```elixir
defmodule Otto.Metrics.Prometheus do
  use Prometheus.Metric

  @counter [
    name: :otto_agents_total,
    help: "Total number of agent invocations",
    labels: [:agent_name, :status]
  ]

  @histogram [
    name: :otto_agent_duration_seconds,
    help: "Agent execution duration",
    labels: [:agent_name],
    buckets: [0.1, 0.5, 1, 2, 5, 10, 30, 60, 300]
  ]

  @gauge [
    name: :otto_active_agents,
    help: "Currently active agents",
    labels: [:node]
  ]

  @counter [
    name: :otto_budget_exceeded_total,
    help: "Budget exceeded events",
    labels: [:agent_name, :budget_type]
  ]

  @histogram [
    name: :otto_token_usage,
    help: "Token usage per invocation",
    labels: [:agent_name, :model],
    buckets: [100, 500, 1000, 2000, 5000, 10000, 20000, 50000]
  ]

  def setup do
    Counter.declare(@counter)
    Histogram.declare(@histogram)
    Gauge.declare(@gauge)
  end

  def record_agent_completion(agent_name, status, duration_ms, token_count) do
    Counter.inc([name: :otto_agents_total, labels: [agent_name, status]])
    Histogram.observe([name: :otto_agent_duration_seconds, labels: [agent_name]], duration_ms / 1000)
    Histogram.observe([name: :otto_token_usage, labels: [agent_name, "claude-3"]], token_count)
  end
end
```

### Grafana Dashboards

#### System Overview Dashboard

```json
{
  "dashboard": {
    "title": "Otto System Overview",
    "panels": [
      {
        "title": "Agent Invocations Rate",
        "type": "stat",
        "targets": [
          {
            "expr": "rate(otto_agents_total[5m])",
            "legendFormat": "{{status}}"
          }
        ]
      },
      {
        "title": "Active Agents",
        "type": "stat",
        "targets": [
          {
            "expr": "otto_active_agents",
            "legendFormat": "Active"
          }
        ]
      },
      {
        "title": "Agent Success Rate",
        "type": "stat",
        "targets": [
          {
            "expr": "rate(otto_agents_total{status=\"completed\"}[5m]) / rate(otto_agents_total[5m]) * 100",
            "legendFormat": "Success %"
          }
        ]
      },
      {
        "title": "Response Time P95",
        "type": "graph",
        "targets": [
          {
            "expr": "histogram_quantile(0.95, rate(otto_agent_duration_seconds_bucket[5m]))",
            "legendFormat": "P95"
          }
        ]
      },
      {
        "title": "Token Usage",
        "type": "graph",
        "targets": [
          {
            "expr": "rate(otto_token_usage_sum[5m])",
            "legendFormat": "Tokens/sec"
          }
        ]
      },
      {
        "title": "Budget Exceeded Events",
        "type": "graph",
        "targets": [
          {
            "expr": "rate(otto_budget_exceeded_total[5m])",
            "legendFormat": "{{budget_type}}"
          }
        ]
      }
    ]
  }
}
```

### Structured Logging

```elixir
defmodule Otto.Logging do
  require Logger

  def log_agent_event(event, agent_id, metadata \\ %{}) do
    Logger.info("Agent event",
      event: event,
      agent_id: agent_id,
      correlation_id: metadata[:correlation_id],
      duration_ms: metadata[:duration_ms],
      tokens_used: metadata[:tokens_used],
      cost_cents: metadata[:cost_cents],
      timestamp: DateTime.utc_now()
    )
  end

  def log_error(error, context \\ %{}) do
    Logger.error("Otto error",
      error: inspect(error),
      context: context,
      stacktrace: Process.info(self(), :current_stacktrace),
      timestamp: DateTime.utc_now()
    )
  end

  def log_performance_warning(metric, value, threshold, context \\ %{}) do
    Logger.warn("Performance warning",
      metric: metric,
      value: value,
      threshold: threshold,
      context: context,
      timestamp: DateTime.utc_now()
    )
  end
end
```

### Health Checks

```elixir
defmodule Otto.Health do
  @moduledoc """
  Health check endpoints for load balancers and monitoring.
  """

  def check_system_health do
    checks = [
      {:database, &check_database/0},
      {:tool_bus, &check_tool_bus/0},
      {:llm_provider, &check_llm_provider/0},
      {:disk_space, &check_disk_space/0},
      {:memory_usage, &check_memory_usage/0}
    ]

    results = Enum.map(checks, fn {name, check_func} ->
      try do
        case check_func.() do
          :ok -> {name, :healthy, nil}
          {:ok, details} -> {name, :healthy, details}
          {:error, reason} -> {name, :unhealthy, reason}
        end
      rescue
        exception -> {name, :error, Exception.message(exception)}
      end
    end)

    overall_status = if Enum.all?(results, fn {_, status, _} -> status == :healthy end) do
      :healthy
    else
      :unhealthy
    end

    %{
      status: overall_status,
      checks: Map.new(results, fn {name, status, details} -> {name, %{status: status, details: details}} end),
      timestamp: DateTime.utc_now(),
      version: Application.spec(:otto, :vsn)
    }
  end

  defp check_database do
    case Ecto.Adapters.SQL.query(Otto.Repo, "SELECT 1", []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "Database connection failed: #{inspect(reason)}"}
    end
  end

  defp check_tool_bus do
    case GenServer.call(Otto.ToolBus, :health_check, 5000) do
      :ok -> {:ok, %{registered_tools: length(Otto.ToolBus.list_tools())}}
      error -> {:error, "ToolBus unhealthy: #{inspect(error)}"}
    end
  end

  defp check_llm_provider do
    # Test connection to Anthropic API
    case HTTPoison.get("https://api.anthropic.com/v1/messages",
                      [{"Authorization", "Bearer #{get_api_key()}"}],
                      timeout: 10_000) do
      {:ok, %{status_code: status}} when status in 200..299 -> :ok
      {:ok, %{status_code: 401}} -> {:error, "Invalid API key"}
      {:ok, %{status_code: status}} -> {:error, "API returned status #{status}"}
      {:error, reason} -> {:error, "API connection failed: #{inspect(reason)}"}
    end
  end

  defp check_disk_space do
    checkpoint_dir = Application.get_env(:otto, :checkpoint_dir, "/app/var/otto/sessions")

    case File.stat(checkpoint_dir) do
      {:ok, _} ->
        case System.cmd("df", [checkpoint_dir]) do
          {output, 0} ->
            # Parse df output to get usage percentage
            usage_line = output |> String.split("\n") |> Enum.at(1)
            usage_pct = usage_line |> String.split() |> Enum.at(4) |> String.trim_trailing("%") |> String.to_integer()

            if usage_pct > 90 do
              {:error, "Disk usage at #{usage_pct}%"}
            else
              {:ok, %{disk_usage_percent: usage_pct}}
            end
          _ ->
            {:error, "Could not check disk usage"}
        end
      {:error, reason} ->
        {:error, "Checkpoint directory not accessible: #{reason}"}
    end
  end

  defp check_memory_usage do
    memory_info = :erlang.memory()
    total_mb = memory_info[:total] / 1024 / 1024

    # Get system memory limit
    system_memory = get_system_memory_mb()
    usage_percent = (total_mb / system_memory * 100) |> round()

    if usage_percent > 90 do
      {:error, "Memory usage at #{usage_percent}%"}
    else
      {:ok, %{memory_usage_percent: usage_percent, memory_mb: round(total_mb)}}
    end
  end

  defp get_api_key do
    System.get_env("ANTHROPIC_API_KEY") || Application.get_env(:otto, :anthropic_api_key)
  end

  defp get_system_memory_mb do
    case System.cmd("free", ["-m"]) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.at(1)  # Memory line
        |> String.split()
        |> Enum.at(1)  # Total memory column
        |> String.to_integer()
      _ ->
        4096  # Default assumption
    end
  end
end
```

### Alerting Rules

#### Prometheus AlertManager Rules

```yaml
# otto-alerts.yml
groups:
- name: otto
  rules:
  - alert: OttoHighErrorRate
    expr: rate(otto_agents_total{status="failed"}[5m]) / rate(otto_agents_total[5m]) > 0.05
    for: 2m
    labels:
      severity: warning
    annotations:
      summary: "Otto agent failure rate is high"
      description: "Otto agent failure rate is {{ $value | humanizePercentage }} over the last 5 minutes"

  - alert: OttoResponseTimeHigh
    expr: histogram_quantile(0.95, rate(otto_agent_duration_seconds_bucket[5m])) > 30
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Otto response time is high"
      description: "95th percentile response time is {{ $value }}s"

  - alert: OttoBudgetExceededSpike
    expr: rate(otto_budget_exceeded_total[5m]) > 1
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "Otto budget exceeded events spike"
      description: "Budget exceeded rate: {{ $value }} events/sec"

  - alert: OttoSystemDown
    expr: up{job="otto"} == 0
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "Otto system is down"
      description: "Otto instance {{ $labels.instance }} is down"

  - alert: OttoHighMemoryUsage
    expr: otto_memory_usage_percent > 85
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Otto memory usage is high"
      description: "Memory usage is {{ $value }}%"

  - alert: OttoDiskSpaceLow
    expr: otto_disk_usage_percent > 90
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "Otto disk space is low"
      description: "Disk usage is {{ $value }}%"
```

## Performance Tuning

### VM Configuration

```bash
# config/vm.args
+P 1048576                      # Max processes
+Q 1048576                      # Max ports
+K true                         # Enable kernel polling
+A 64                           # Async thread pool size
+sbt db                         # Bind schedulers to cores
+sbwt none                      # No scheduler bind to logical cores
+swt low                        # Low scheduler wakeup threshold
+sbwt none                      # No busy wait threshold
+C multi_time_warp              # Time warp mode

# Memory
+hms 8192                       # Min heap size (MB)
+hmm 16384                      # Max heap size (MB)

# GC tuning
+hpz 0                          # Parallel GC
+hmaxel 16384                   # Max ETS tables

# Distribution
-proto_dist inet_tcp            # TCP distribution
-inet_dist_listen_min 9000      # Port range start
-inet_dist_listen_max 9999      # Port range end
```

### Application Configuration

```elixir
# config/prod.exs
config :otto,
  # Agent management
  max_concurrent_agents: System.get_env("OTTO_MAX_CONCURRENT_AGENTS", "100") |> String.to_integer(),
  agent_timeout_ms: 300_000,
  agent_cleanup_interval: 60_000,

  # Tool configuration
  tool_timeout_ms: 30_000,
  tool_retry_attempts: 3,
  tool_retry_backoff: 1000,

  # Checkpoint configuration
  checkpoint_enabled: true,
  checkpoint_batch_size: 100,
  checkpoint_flush_interval: 5000,
  checkpoint_compression: :gzip,

  # Context store (ETS) configuration
  context_store_size: 10_000_000,  # 10M entries max
  context_store_cleanup_interval: 300_000,  # 5 minutes
  context_store_memory_limit: 1_073_741_824,  # 1GB

  # Budget enforcement
  budget_check_interval: 1000,
  budget_warning_threshold: 0.8,
  budget_grace_period: 10_000,

  # Connection pools
  http_pool_size: 50,
  http_pool_timeout: 30_000,

  # Database
  database_pool_size: 20,
  database_timeout: 15_000,
  database_queue_target: 50,
  database_queue_interval: 1000

# Phoenix endpoint
config :otto_live, OttoLiveWeb.Endpoint,
  http: [
    port: 4000,
    compress: true,
    protocol_options: [
      max_connections: 16_384,
      max_keepalive: 1024
    ]
  ],
  server: true,

  # LiveView configuration
  live_view: [
    signing_salt: System.get_env("SECRET_KEY_BASE")
  ],

  # Telemetry
  telemetry_prefix: [:otto_live, :endpoint]
```

### Database Optimizations

```sql
-- PostgreSQL optimizations for Otto

-- Indexes for common queries
CREATE INDEX CONCURRENTLY idx_agent_sessions_created_at
ON agent_sessions (created_at);

CREATE INDEX CONCURRENTLY idx_agent_sessions_agent_id
ON agent_sessions (agent_id);

CREATE INDEX CONCURRENTLY idx_checkpoints_correlation_id
ON checkpoints (correlation_id);

CREATE INDEX CONCURRENTLY idx_cost_tracking_agent_id_date
ON cost_tracking (agent_id, date);

-- Connection pooling
ALTER SYSTEM SET max_connections = 200;
ALTER SYSTEM SET shared_buffers = '1GB';
ALTER SYSTEM SET effective_cache_size = '3GB';
ALTER SYSTEM SET work_mem = '16MB';
ALTER SYSTEM SET maintenance_work_mem = '256MB';

-- Logging for monitoring
ALTER SYSTEM SET log_min_duration_statement = '1000';
ALTER SYSTEM SET log_checkpoints = on;
ALTER SYSTEM SET log_lock_waits = on;

-- Checkpointing
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
ALTER SYSTEM SET wal_buffers = '16MB';

SELECT pg_reload_conf();
```

### Performance Monitoring

```elixir
defmodule Otto.Performance.Monitor do
  use GenServer
  require Logger

  @monitor_interval 30_000  # 30 seconds

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    schedule_monitoring()
    {:ok, %{last_metrics: %{}}}
  end

  def handle_info(:monitor, state) do
    current_metrics = collect_metrics()

    # Check for performance issues
    check_memory_usage(current_metrics)
    check_agent_queue_length(current_metrics)
    check_response_times(current_metrics)
    check_error_rates(current_metrics)

    schedule_monitoring()
    {:noreply, %{state | last_metrics: current_metrics}}
  end

  defp collect_metrics do
    %{
      memory_usage: :erlang.memory(),
      process_count: :erlang.system_info(:process_count),
      agent_count: Otto.Registry.count_agents(),
      queue_length: Otto.AgentSupervisor.queue_length(),
      response_times: get_recent_response_times(),
      error_count: get_recent_error_count(),
      timestamp: System.monotonic_time(:millisecond)
    }
  end

  defp check_memory_usage(metrics) do
    total_mb = metrics.memory_usage[:total] / 1024 / 1024

    if total_mb > 8192 do  # 8GB threshold
      Logger.warn("High memory usage detected",
        memory_mb: total_mb,
        process_count: metrics.process_count
      )
    end
  end

  defp check_agent_queue_length(metrics) do
    if metrics.queue_length > 50 do
      Logger.warn("Agent queue length high",
        queue_length: metrics.queue_length,
        active_agents: metrics.agent_count
      )
    end
  end

  defp schedule_monitoring do
    Process.send_after(self(), :monitor, @monitor_interval)
  end
end
```

## Scaling Strategies

### Horizontal Scaling

#### Load Balancer Configuration (nginx)

```nginx
upstream otto_backend {
    least_conn;
    server otto-1:4000 max_fails=3 fail_timeout=30s;
    server otto-2:4000 max_fails=3 fail_timeout=30s;
    server otto-3:4000 max_fails=3 fail_timeout=30s;

    # Health check
    keepalive 32;
}

server {
    listen 80;
    listen 443 ssl http2;

    server_name otto.yourdomain.com;

    # SSL configuration
    ssl_certificate /etc/ssl/certs/otto.crt;
    ssl_certificate_key /etc/ssl/private/otto.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;

    # Proxy configuration
    location / {
        proxy_pass http://otto_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 300s;  # Allow long agent executions

        # Buffer settings
        proxy_buffering on;
        proxy_buffer_size 16k;
        proxy_buffers 8 16k;
        proxy_busy_buffers_size 32k;
    }

    # Health check endpoint
    location /health {
        proxy_pass http://otto_backend;
        proxy_connect_timeout 5s;
        proxy_read_timeout 5s;
        access_log off;
    }

    # Static files
    location /static/ {
        root /var/www/otto;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
```

#### Distributed Configuration

```elixir
# config/prod.exs for distributed deployment
config :otto,
  # Distributed Erlang
  node_name: System.get_env("NODE_NAME") || "otto@127.0.0.1",
  cookie: System.get_env("ERLANG_COOKIE") || :otto_cluster,

  # Cluster strategy
  cluster_strategy: Otto.Cluster.EtcdStrategy,
  cluster_config: [
    etcd_host: System.get_env("ETCD_HOST", "localhost"),
    etcd_port: System.get_env("ETCD_PORT", "2379") |> String.to_integer(),
    node_ttl: 60_000,
    heartbeat_interval: 30_000
  ],

  # Distributed agent scheduling
  agent_scheduler: Otto.Scheduler.Distributed,
  scheduler_config: [
    load_balancing: :least_loaded,
    health_check_interval: 10_000,
    node_capacity: %{
      max_agents: 100,
      memory_limit: 8_192_000_000  # 8GB
    }
  ]

# Distributed registry
config :otto, Otto.Registry,
  adapter: Otto.Registry.Distributed,
  sync_interval: 5_000,
  cleanup_interval: 60_000
```

### Auto-scaling

#### Kubernetes HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: otto-hpa
  namespace: otto-system
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: otto
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  - type: Pods
    pods:
      metric:
        name: otto_active_agents
      target:
        type: AverageValue
        averageValue: "50"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
```

#### Custom Metrics Auto-scaling

```elixir
defmodule Otto.AutoScaler do
  use GenServer
  require Logger

  @scale_check_interval 30_000  # 30 seconds
  @scale_up_threshold 0.8       # 80% resource utilization
  @scale_down_threshold 0.3     # 30% resource utilization

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    schedule_scale_check()
    {:ok, %{last_scale_action: nil}}
  end

  def handle_info(:scale_check, state) do
    try_auto_scale()
    schedule_scale_check()
    {:noreply, state}
  end

  defp try_auto_scale do
    metrics = collect_scaling_metrics()

    cond do
      should_scale_up?(metrics) ->
        scale_up(metrics)

      should_scale_down?(metrics) ->
        scale_down(metrics)

      true ->
        :no_action
    end
  end

  defp collect_scaling_metrics do
    %{
      cpu_usage: get_cpu_usage(),
      memory_usage: get_memory_usage(),
      active_agents: Otto.Registry.count_agents(),
      queue_length: Otto.AgentSupervisor.queue_length(),
      response_time_p95: get_response_time_percentile(0.95),
      error_rate: get_error_rate()
    }
  end

  defp should_scale_up?(metrics) do
    metrics.cpu_usage > @scale_up_threshold or
    metrics.memory_usage > @scale_up_threshold or
    metrics.queue_length > 20 or
    metrics.response_time_p95 > 60_000  # 60 seconds
  end

  defp should_scale_down?(metrics) do
    metrics.cpu_usage < @scale_down_threshold and
    metrics.memory_usage < @scale_down_threshold and
    metrics.queue_length < 5 and
    metrics.active_agents < 10
  end

  defp scale_up(metrics) do
    current_replicas = get_current_replicas()
    new_replicas = min(current_replicas + 1, 10)  # Max 10 replicas

    Logger.info("Scaling up Otto deployment",
      current_replicas: current_replicas,
      new_replicas: new_replicas,
      trigger_metrics: metrics
    )

    kubectl_scale(new_replicas)
  end

  defp scale_down(metrics) do
    current_replicas = get_current_replicas()
    new_replicas = max(current_replicas - 1, 2)  # Min 2 replicas

    Logger.info("Scaling down Otto deployment",
      current_replicas: current_replicas,
      new_replicas: new_replicas,
      metrics: metrics
    )

    kubectl_scale(new_replicas)
  end

  defp kubectl_scale(replicas) do
    case System.cmd("kubectl", [
      "scale", "deployment", "otto",
      "--replicas=#{replicas}",
      "-n", "otto-system"
    ]) do
      {_, 0} -> :ok
      {error, _} ->
        Logger.error("Failed to scale deployment: #{error}")
        :error
    end
  end
end
```

## Security Hardening

### Network Security

```bash
# Firewall configuration (iptables)
#!/bin/bash

# Flush existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# Set default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow SSH (change port as needed)
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT

# Allow HTTP/HTTPS
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Allow health check port
iptables -A INPUT -p tcp --dport 4000 -s 10.0.0.0/8 -j ACCEPT  # Internal only

# Allow Prometheus metrics (internal only)
iptables -A INPUT -p tcp --dport 9090 -s 10.0.0.0/8 -j ACCEPT

# Allow PostgreSQL (internal only)
iptables -A INPUT -p tcp --dport 5432 -s 10.0.0.0/8 -j ACCEPT

# Allow Erlang distribution (internal only)
iptables -A INPUT -p tcp --dport 9000:9999 -s 10.0.0.0/8 -j ACCEPT

# Log dropped packets (limit to prevent log spam)
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables denied: "

# Drop everything else
iptables -A INPUT -j DROP

# Save rules
iptables-save > /etc/iptables/rules.v4
```

### Application Security

```elixir
# lib/otto/security.ex
defmodule Otto.Security do
  @moduledoc """
  Security hardening for Otto application.
  """

  def setup_security_headers do
    # Content Security Policy
    csp_policy = [
      "default-src 'self'",
      "script-src 'self' 'unsafe-inline'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: https:",
      "connect-src 'self'",
      "font-src 'self'",
      "object-src 'none'",
      "media-src 'none'",
      "frame-src 'none'"
    ] |> Enum.join("; ")

    [
      {"Content-Security-Policy", csp_policy},
      {"X-Frame-Options", "DENY"},
      {"X-Content-Type-Options", "nosniff"},
      {"X-XSS-Protection", "1; mode=block"},
      {"Referrer-Policy", "strict-origin-when-cross-origin"},
      {"Permissions-Policy", "accelerometer=(), camera=(), geolocation=(), microphone=()"}
    ]
  end

  def validate_api_key(api_key) do
    case api_key do
      nil -> {:error, :missing_api_key}
      "" -> {:error, :empty_api_key}
      key when is_binary(key) ->
        if String.length(key) >= 32 and String.starts_with?(key, ["sk-", "api-"]) do
          :ok
        else
          {:error, :invalid_api_key_format}
        end
      _ -> {:error, :invalid_api_key_type}
    end
  end

  def sanitize_user_input(input) when is_binary(input) do
    input
    |> String.trim()
    |> String.replace(~r/[<>\"']/, "")  # Remove HTML chars
    |> String.replace(~r/\x00/, "")     # Remove null bytes
    |> String.slice(0, 10_000)          # Limit length
  end

  def validate_file_path(path, allowed_paths) do
    normalized_path = Path.expand(path)

    # Check for path traversal
    if String.contains?(path, ["../", "..\\", "~/"]) do
      {:error, :path_traversal_attempt}
    else
      # Check against allowed paths
      if Enum.any?(allowed_paths, &String.starts_with?(normalized_path, &1)) do
        {:ok, normalized_path}
      else
        {:error, :path_not_allowed}
      end
    end
  end

  def audit_log(event, user_id, details \\ %{}) do
    Logger.info("Security audit",
      event: event,
      user_id: user_id,
      details: details,
      timestamp: DateTime.utc_now(),
      ip_address: get_client_ip(),
      user_agent: get_user_agent()
    )
  end

  defp get_client_ip do
    # Implementation depends on your setup
    # Usually from request headers or connection info
    "0.0.0.0"
  end

  defp get_user_agent do
    # Implementation depends on your setup
    "unknown"
  end
end
```

### Secrets Management

```elixir
defmodule Otto.Secrets do
  @moduledoc """
  Secure secrets management for Otto.
  """

  @secret_keys [
    :anthropic_api_key,
    :database_url,
    :secret_key_base,
    :slack_webhook_url,
    :slack_bot_token
  ]

  def load_secrets do
    Enum.each(@secret_keys, &load_secret/1)
  end

  defp load_secret(key) do
    secret_value = case get_secret_source() do
      :vault -> load_from_vault(key)
      :k8s_secrets -> load_from_k8s_secret(key)
      :env -> System.get_env(key |> to_env_var())
    end

    if secret_value do
      Application.put_env(:otto, key, secret_value)
    else
      Logger.warn("Secret not found: #{key}")
    end
  end

  defp get_secret_source do
    cond do
      System.get_env("VAULT_ADDR") -> :vault
      System.get_env("KUBERNETES_SERVICE_HOST") -> :k8s_secrets
      true -> :env
    end
  end

  defp load_from_vault(key) do
    # Implementation for HashiCorp Vault
    vault_path = "secret/otto/#{key}"

    case Vault.read(vault_path) do
      {:ok, %{"data" => %{"value" => value}}} -> value
      _ -> nil
    end
  end

  defp load_from_k8s_secret(key) do
    secret_file = "/var/secrets/#{key}"

    case File.read(secret_file) do
      {:ok, content} -> String.trim(content)
      _ -> nil
    end
  end

  defp to_env_var(atom) do
    atom |> to_string() |> String.upcase()
  end

  def mask_secret(secret) when is_binary(secret) do
    case String.length(secret) do
      len when len <= 4 -> "***"
      len when len <= 8 -> String.slice(secret, 0, 2) <> "***"
      _ -> String.slice(secret, 0, 4) <> "***" <> String.slice(secret, -4, 4)
    end
  end

  def mask_secret(_), do: "***"
end
```

## Backup & Recovery

### Automated Backups

```bash
#!/bin/bash
# backup-otto.sh

set -e

BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/otto/${BACKUP_DATE}"
RETENTION_DAYS=30

# Create backup directory
mkdir -p "${BACKUP_DIR}"

echo "Starting Otto backup at $(date)"

# 1. Database backup
echo "Backing up PostgreSQL database..."
PGPASSWORD="${DB_PASSWORD}" pg_dump \
    -h "${DB_HOST}" \
    -U "${DB_USER}" \
    -d "${DB_NAME}" \
    --verbose \
    --no-owner \
    --no-privileges \
    --format=custom \
    --file="${BACKUP_DIR}/database.dump"

# 2. Checkpoint data backup
echo "Backing up checkpoint data..."
if [ -d "/app/var/otto/sessions" ]; then
    tar -czf "${BACKUP_DIR}/checkpoints.tar.gz" \
        -C "/app/var/otto" \
        sessions/
fi

# 3. Configuration backup
echo "Backing up configuration..."
tar -czf "${BACKUP_DIR}/config.tar.gz" \
    -C "/app" \
    .otto/ \
    config/

# 4. Application logs (last 7 days)
echo "Backing up recent logs..."
find /app/var/logs -name "*.log" -mtime -7 | \
    tar -czf "${BACKUP_DIR}/logs.tar.gz" -T -

# 5. ETS table snapshots (if persistent)
echo "Backing up ETS data..."
if [ -d "/app/var/ets" ]; then
    tar -czf "${BACKUP_DIR}/ets_data.tar.gz" \
        -C "/app/var" \
        ets/
fi

# 6. Create backup manifest
cat > "${BACKUP_DIR}/manifest.json" << EOF
{
  "backup_date": "${BACKUP_DATE}",
  "otto_version": "$(mix version 2>/dev/null || echo 'unknown')",
  "database_size": $(stat -c%s "${BACKUP_DIR}/database.dump"),
  "files": [
    "database.dump",
    "checkpoints.tar.gz",
    "config.tar.gz",
    "logs.tar.gz",
    "ets_data.tar.gz"
  ],
  "created_by": "$(whoami)",
  "hostname": "$(hostname)"
}
EOF

# 7. Upload to S3 (optional)
if [ -n "${S3_BACKUP_BUCKET}" ]; then
    echo "Uploading backup to S3..."
    aws s3 sync "${BACKUP_DIR}" \
        "s3://${S3_BACKUP_BUCKET}/otto-backups/${BACKUP_DATE}/" \
        --storage-class STANDARD_IA
fi

# 8. Cleanup old backups
echo "Cleaning up old backups..."
find /backups/otto -type d -mtime +${RETENTION_DAYS} -exec rm -rf {} +

# 9. Verify backup integrity
echo "Verifying backup integrity..."
if pg_restore --list "${BACKUP_DIR}/database.dump" > /dev/null; then
    echo "Database backup verified successfully"
else
    echo "ERROR: Database backup verification failed"
    exit 1
fi

echo "Otto backup completed successfully at $(date)"

# Log backup status
logger "Otto backup completed: ${BACKUP_DIR}"
```

### Recovery Procedures

```bash
#!/bin/bash
# restore-otto.sh

set -e

BACKUP_DATE="$1"
BACKUP_DIR="/backups/otto/${BACKUP_DATE}"

if [ -z "$BACKUP_DATE" ]; then
    echo "Usage: $0 <backup_date>"
    echo "Available backups:"
    ls -1 /backups/otto/
    exit 1
fi

if [ ! -d "$BACKUP_DIR" ]; then
    echo "Backup directory not found: $BACKUP_DIR"
    exit 1
fi

echo "Starting Otto restore from backup: ${BACKUP_DATE}"

# 1. Stop Otto services
echo "Stopping Otto services..."
systemctl stop otto || docker-compose down

# 2. Backup current state (just in case)
echo "Creating current state backup..."
CURRENT_BACKUP="/backups/otto/pre_restore_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$CURRENT_BACKUP"
pg_dump "$DATABASE_URL" > "$CURRENT_BACKUP/current_database.sql"

# 3. Restore database
echo "Restoring database..."
dropdb "$DB_NAME" 2>/dev/null || true
createdb "$DB_NAME"
pg_restore --verbose --no-owner --no-privileges \
    -d "$DB_NAME" "$BACKUP_DIR/database.dump"

# 4. Restore checkpoint data
echo "Restoring checkpoint data..."
rm -rf /app/var/otto/sessions
mkdir -p /app/var/otto
tar -xzf "$BACKUP_DIR/checkpoints.tar.gz" -C /app/var/otto/

# 5. Restore configuration
echo "Restoring configuration..."
rm -rf /app/.otto
tar -xzf "$BACKUP_DIR/config.tar.gz" -C /app/

# 6. Restore ETS data
echo "Restoring ETS data..."
if [ -f "$BACKUP_DIR/ets_data.tar.gz" ]; then
    rm -rf /app/var/ets
    mkdir -p /app/var
    tar -xzf "$BACKUP_DIR/ets_data.tar.gz" -C /app/var/
fi

# 7. Set proper permissions
echo "Setting permissions..."
chown -R otto:otto /app/var/otto
chmod -R 755 /app/var/otto

# 8. Validate restore
echo "Validating restore..."
# Check database connection
if psql "$DATABASE_URL" -c "SELECT 1;" > /dev/null; then
    echo "Database restore verified"
else
    echo "ERROR: Database restore failed"
    exit 1
fi

# Check essential files
if [ ! -d "/app/.otto/agents" ]; then
    echo "ERROR: Configuration restore failed"
    exit 1
fi

# 9. Start Otto services
echo "Starting Otto services..."
systemctl start otto || docker-compose up -d

# Wait for service to be ready
echo "Waiting for Otto to be ready..."
for i in {1..30}; do
    if curl -f http://localhost:4000/health > /dev/null 2>&1; then
        echo "Otto is ready!"
        break
    fi
    sleep 5
done

echo "Otto restore completed successfully at $(date)"
```

### Disaster Recovery Plan

```markdown
# Otto Disaster Recovery Plan

## Recovery Time Objectives (RTO)
- **Critical**: 4 hours
- **Non-critical**: 24 hours

## Recovery Point Objectives (RPO)
- **Database**: 1 hour (continuous backup)
- **Checkpoint data**: 1 hour
- **Configuration**: 24 hours

## Disaster Scenarios

### 1. Single Node Failure
**RTO**: 15 minutes
**Steps**:
1. Load balancer detects failure
2. Traffic redirected to healthy nodes
3. Auto-scaling triggers new instance
4. New instance joins cluster

### 2. Database Failure
**RTO**: 30 minutes
**Steps**:
1. Switch to read replica (if available)
2. Restore from latest backup
3. Update connection strings
4. Restart Otto services

### 3. Complete Datacenter Loss
**RTO**: 4 hours
**Steps**:
1. Activate DR site
2. Restore from S3/cross-region backups
3. Update DNS to point to DR site
4. Validate all services

### 4. Backup Corruption
**RTO**: 2 hours
**Steps**:
1. Identify last known good backup
2. Restore from older backup
3. Apply transaction logs if available
4. Validate data integrity

## Emergency Contacts
- Primary: ops@company.com
- Secondary: cto@company.com
- Otto Support: support@otto-ai.com

## Recovery Validation Checklist
- [ ] Database accessible and consistent
- [ ] All Otto nodes responding to health checks
- [ ] Agent invocations working
- [ ] Tool registry populated
- [ ] Monitoring systems operational
- [ ] Backup systems functional
```

## Troubleshooting

### Common Issues

#### 1. High Memory Usage

**Symptoms**:
- Memory usage > 85%
- Frequent garbage collection
- Slow response times

**Diagnosis**:
```elixir
# In IEx
:recon.memory_usage(:total)
:recon.proc_count(:memory, 10)  # Top 10 processes by memory

# Check ETS table sizes
:ets.all() |> Enum.map(fn tab ->
  {tab, :ets.info(tab, :memory), :ets.info(tab, :size)}
end) |> Enum.sort_by(fn {_, mem, _} -> mem end, :desc)
```

**Solutions**:
```elixir
# Tune transcript limits
config :otto,
  transcript_limit: 500  # Reduce from default 1000

# Enable ETS memory limits
config :otto, Otto.ContextStore,
  memory_limit: 500_000_000,  # 500MB limit
  cleanup_interval: 60_000

# Tune garbage collection
# In vm.args
+hms 4096    # Reduce min heap size
+hmaxel 8192 # Reduce max ETS tables
```

#### 2. Budget Exceeded Errors

**Symptoms**:
- Many agents failing with budget exceeded
- High token usage
- Unexpected cost increases

**Diagnosis**:
```elixir
# Check budget usage patterns
Otto.CostTracker.get_usage(:all, Date.utc_today())

# Analyze token usage by agent
agents = Otto.Registry.list_agents()
Enum.map(agents, fn agent ->
  status = Otto.Agent.get_status(agent)
  {agent, status.budget_utilization}
end)
```

**Solutions**:
```yaml
# Adjust budgets in agent configs
budgets:
  time_seconds: 600    # Increase time limit
  tokens: 25000        # Increase token limit
  cost_cents: 200      # Increase cost limit

# Use more efficient models
model: "claude-3-haiku-20240307"  # More cost-effective

# Optimize system prompts
system_prompt: |
  Be concise and direct. Avoid verbose explanations.
```

#### 3. Tool Timeout Issues

**Symptoms**:
- Tools timing out frequently
- HTTP request failures
- File operation errors

**Diagnosis**:
```bash
# Check network connectivity
ping api.anthropic.com
curl -I https://api.anthropic.com

# Check disk I/O
iostat -x 1 10

# Check file permissions
ls -la /app/var/otto/sessions
```

**Solutions**:
```yaml
# Increase tool timeouts
tool_config:
  http.get:
    timeout_ms: 60000  # Increase from 30 seconds
  fs.read:
    timeout_ms: 10000  # Add explicit timeout
  grep:
    timeout_ms: 20000  # Increase search timeout
```

#### 4. Agent Queue Buildup

**Symptoms**:
- Long wait times for agent responses
- Queue length growing
- Resource exhaustion

**Diagnosis**:
```elixir
# Check queue status
Otto.AgentSupervisor.queue_length()
Otto.Registry.count_agents()

# Check resource usage
:recon.proc_count(:reductions, 10)
:observer.start()  # GUI for detailed analysis
```

**Solutions**:
```elixir
# Increase concurrency limits
config :otto,
  max_concurrent_agents: 200  # Increase from 100

# Add more worker processes
config :otto, Otto.AgentSupervisor,
  max_children: 500,
  strategy: :simple_one_for_one

# Scale horizontally
# Deploy additional Otto instances
```

### Debugging Tools

#### 1. Live Dashboard

```elixir
# lib/otto_live_web/router.ex
if Mix.env() in [:dev, :test] do
  import Phoenix.LiveDashboard.Router

  scope "/" do
    pipe_through [:fetch_session, :protect_from_forgery]

    live_dashboard "/dashboard",
      metrics: Otto.Telemetry,
      additional_pages: [
        agents: Otto.LiveDashboard.AgentsPage,
        tools: Otto.LiveDashboard.ToolsPage,
        budgets: Otto.LiveDashboard.BudgetsPage
      ]
  end
end
```

#### 2. Custom Debug Tools

```elixir
defmodule Otto.Debug do
  @moduledoc """
  Debug utilities for Otto troubleshooting.
  """

  def system_status do
    %{
      node: Node.self(),
      uptime: :erlang.statistics(:wall_clock) |> elem(0),
      memory: :erlang.memory(),
      process_count: :erlang.system_info(:process_count),
      agents: %{
        active: Otto.Registry.count_agents(),
        queue_length: Otto.AgentSupervisor.queue_length()
      },
      tools: %{
        registered: length(Otto.ToolBus.list_tools()),
        registry_size: GenServer.call(Otto.ToolBus, :registry_size)
      }
    }
  end

  def agent_details(agent_id) do
    case Otto.Registry.lookup_agent(agent_id) do
      {:ok, pid} ->
        state = :sys.get_state(pid)
        %{
          pid: pid,
          status: state.status,
          config: state.config,
          uptime: DateTime.diff(DateTime.utc_now(), state.metadata.created_at, :millisecond),
          invocation_count: state.metadata.invocation_count,
          budget_utilization: calculate_budget_utilization(state.budgets),
          transcript_size: CircularBuffer.size(state.transcript)
        }
      {:error, :not_found} ->
        {:error, "Agent not found: #{agent_id}"}
    end
  end

  def tool_diagnostics do
    tools = Otto.ToolBus.list_tools()

    Enum.map(tools, fn tool_name ->
      {:ok, module} = Otto.ToolBus.get_tool(tool_name)

      %{
        name: tool_name,
        module: module,
        permissions: module.permissions(),
        healthy: test_tool_health(tool_name),
        call_count: get_tool_call_count(tool_name)
      }
    end)
  end

  def performance_profile(duration_ms \\ 10_000) do
    # Start profiling
    :fprof.start()
    :fprof.trace(:start, procs: :all)

    Process.sleep(duration_ms)

    # Stop profiling and analyze
    :fprof.trace(:stop)
    :fprof.profile()
    :fprof.analyse()
    :fprof.stop()

    "Profile saved to fprof.analysis"
  end

  defp calculate_budget_utilization(budgets) do
    %{
      time: budgets.time.used / budgets.time.limit,
      tokens: budgets.tokens.used / budgets.tokens.limit,
      cost: budgets.cost.used / budgets.cost.limit
    }
  end

  defp test_tool_health(tool_name) do
    try do
      case Otto.ToolBus.get_tool(tool_name) do
        {:ok, module} ->
          # Basic health check - module is loaded and has required functions
          function_exported?(module, :call, 2) and
          function_exported?(module, :permissions, 0)
        _ ->
          false
      end
    rescue
      _ -> false
    end
  end

  defp get_tool_call_count(tool_name) do
    # This would require implementing call counting in ToolBus
    case :ets.lookup(:tool_metrics, tool_name) do
      [{^tool_name, count, _}] -> count
      [] -> 0
    end
  end
end
```

## Maintenance Procedures

### Regular Maintenance Tasks

#### Daily Tasks

```bash
#!/bin/bash
# daily-maintenance.sh

echo "Starting daily Otto maintenance at $(date)"

# 1. Health check
echo "Performing health check..."
curl -f http://localhost:4000/health || {
    echo "Health check failed!"
    systemctl status otto
    exit 1
}

# 2. Check disk space
echo "Checking disk space..."
DISK_USAGE=$(df /app/var/otto | tail -1 | awk '{print $5}' | sed 's/%//')
if [ "$DISK_USAGE" -gt 85 ]; then
    echo "WARNING: Disk usage at ${DISK_USAGE}%"
    # Clean old checkpoints
    find /app/var/otto/sessions -type f -mtime +7 -delete
fi

# 3. Check memory usage
echo "Checking memory usage..."
MEMORY_USAGE=$(free | grep Mem | awk '{printf("%.0f", $3/$2 * 100)}')
if [ "$MEMORY_USAGE" -gt 85 ]; then
    echo "WARNING: Memory usage at ${MEMORY_USAGE}%"
fi

# 4. Rotate logs
echo "Rotating logs..."
logrotate /etc/logrotate.d/otto

# 5. Update metrics
echo "Updating maintenance metrics..."
echo "daily_maintenance_completed $(date +%s)" >> /var/log/otto/metrics.txt

echo "Daily maintenance completed at $(date)"
```

#### Weekly Tasks

```bash
#!/bin/bash
# weekly-maintenance.sh

echo "Starting weekly Otto maintenance at $(date)"

# 1. Database maintenance
echo "Performing database maintenance..."
psql "$DATABASE_URL" -c "VACUUM ANALYZE;"
psql "$DATABASE_URL" -c "REINDEX DATABASE otto_prod;"

# 2. Update dependencies (in staging first)
echo "Checking for dependency updates..."
mix deps.outdated | tee /var/log/otto/deps-outdated.log

# 3. Certificate renewal
echo "Checking SSL certificates..."
certbot renew --dry-run

# 4. Backup verification
echo "Verifying recent backups..."
LATEST_BACKUP=$(ls -1 /backups/otto/ | tail -1)
if [ -n "$LATEST_BACKUP" ]; then
    pg_restore --list "/backups/otto/$LATEST_BACKUP/database.dump" > /dev/null
    echo "Backup verification: OK"
else
    echo "ERROR: No recent backups found"
    exit 1
fi

# 5. Performance analysis
echo "Running performance analysis..."
echo "SELECT query, calls, total_time, mean_time FROM pg_stat_statements ORDER BY total_time DESC LIMIT 10;" | \
    psql "$DATABASE_URL" > /var/log/otto/slow-queries.log

echo "Weekly maintenance completed at $(date)"
```

#### Monthly Tasks

```bash
#!/bin/bash
# monthly-maintenance.sh

echo "Starting monthly Otto maintenance at $(date)"

# 1. Security updates
echo "Applying security updates..."
apt update && apt upgrade -y

# 2. Archive old data
echo "Archiving old checkpoint data..."
find /app/var/otto/sessions -type f -mtime +30 | \
    tar -czf "/backups/otto/archive-$(date +%Y%m).tar.gz" -T -
find /app/var/otto/sessions -type f -mtime +30 -delete

# 3. Capacity planning review
echo "Generating capacity planning report..."
cat > /tmp/capacity-report.txt << EOF
Otto Capacity Report - $(date)
================================

Disk Usage:
$(df -h /app/var)

Memory Trends:
$(grep memory_usage /var/log/otto/metrics.txt | tail -30)

Agent Volume:
$(grep agent_count /var/log/otto/metrics.txt | tail -30)

Top Resource Consumers:
$(grep resource_usage /var/log/otto/agents.log | tail -100 | sort -k3 -nr | head -10)
EOF

# 4. Documentation updates
echo "Updating operational documentation..."
# This would trigger a process to update runbooks, etc.

echo "Monthly maintenance completed at $(date)"
```

### Upgrade Procedures

```bash
#!/bin/bash
# upgrade-otto.sh

NEW_VERSION="$1"
if [ -z "$NEW_VERSION" ]; then
    echo "Usage: $0 <new_version>"
    exit 1
fi

echo "Starting Otto upgrade to version $NEW_VERSION"

# 1. Pre-upgrade backup
echo "Creating pre-upgrade backup..."
./backup-otto.sh

# 2. Download and verify new version
echo "Downloading Otto $NEW_VERSION..."
wget "https://releases.otto-ai.com/v$NEW_VERSION/otto-$NEW_VERSION.tar.gz"
wget "https://releases.otto-ai.com/v$NEW_VERSION/otto-$NEW_VERSION.tar.gz.sha256"

# Verify checksum
sha256sum -c "otto-$NEW_VERSION.tar.gz.sha256" || {
    echo "Checksum verification failed!"
    exit 1
}

# 3. Stop services gracefully
echo "Stopping Otto services..."
systemctl stop otto
sleep 30  # Allow time for graceful shutdown

# 4. Deploy new version
echo "Deploying new version..."
tar -xzf "otto-$NEW_VERSION.tar.gz" -C /opt/
ln -sfn "/opt/otto-$NEW_VERSION" /opt/otto

# 5. Run database migrations
echo "Running database migrations..."
cd /opt/otto
mix ecto.migrate

# 6. Update configuration if needed
echo "Checking configuration compatibility..."
mix otto.config.check

# 7. Start services
echo "Starting Otto services..."
systemctl start otto

# 8. Verify upgrade
echo "Verifying upgrade..."
sleep 60  # Wait for startup

if curl -f http://localhost:4000/health; then
    echo "Upgrade successful!"

    # Clean up old versions (keep last 2)
    cd /opt
    ls -1d otto-* | sort -V | head -n -2 | xargs rm -rf
else
    echo "Upgrade verification failed! Rolling back..."
    systemctl stop otto
    rm /opt/otto
    ln -s "/opt/otto-$(cat /opt/current-version)" /opt/otto
    systemctl start otto
    exit 1
fi

echo "Otto upgrade to $NEW_VERSION completed successfully"
```

---

This comprehensive operational guide covers all aspects of running Otto in production. Start with the basic deployment and monitoring setup, then gradually implement more advanced features like auto-scaling and disaster recovery as your needs grow.

<function_calls>
<invoke name="TodoWrite">
<parameter name="todos">[{"content": "Create comprehensive README.md with Phase 0 overview and quick start guide", "status": "completed", "activeForm": "Creating comprehensive README.md with Phase 0 overview"}, {"content": "Document Otto.Tool behaviour and ToolBus registry with examples", "status": "completed", "activeForm": "Documenting Otto.Tool behaviour and ToolBus registry"}, {"content": "Create API documentation for Otto.Agent.Config with YAML schema", "status": "completed", "activeForm": "Creating API documentation for Otto.Agent.Config"}, {"content": "Document AgentServer lifecycle and state management", "status": "completed", "activeForm": "Documenting AgentServer lifecycle and state management"}, {"content": "Create getting started guide with working examples", "status": "completed", "activeForm": "Creating getting started guide with working examples"}, {"content": "Document tool system with permission model and custom tool creation", "status": "completed", "activeForm": "Documenting tool system with permission model"}, {"content": "Create operational guide with monitoring and performance tuning", "status": "completed", "activeForm": "Creating operational guide with monitoring"}]