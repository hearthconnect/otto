# Ensure Otto.Manager application is started for shared services
Application.ensure_all_started(:otto_manager)

ExUnit.start()
