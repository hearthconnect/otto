defmodule OttoLive.Repo do
  use Ecto.Repo,
    otp_app: :otto_live,
    adapter: Ecto.Adapters.Postgres
end
