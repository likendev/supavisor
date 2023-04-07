defmodule Supavisor.Monitoring.PromEx do
  @moduledoc """
  This module configures the PromEx application for Supavisor. It defines
  the plugins used for collecting metrics, including built-in plugins and custom ones,
  and provides a function to remove remote metrics associated with a specific tenant.
  """

  use PromEx, otp_app: :supavisor
  require Logger

  alias PromEx.Plugins
  alias Supavisor.PromEx.Plugins.{OsMon, Tenant}

  @impl true
  def plugins do
    poll_rate = Application.fetch_env!(:supavisor, :prom_poll_rate)

    [
      # PromEx built in plugins
      Plugins.Application,
      Plugins.Beam,
      {Plugins.Phoenix, router: SupavisorWeb.Router, endpoint: SupavisorWeb.Endpoint},
      Plugins.Ecto,

      # Custom PromEx metrics plugins
      {OsMon, poll_rate: poll_rate},
      {Tenant, poll_rate: poll_rate}
    ]
  end

  @spec remove_metrics(String.t()) :: non_neg_integer()
  def remove_metrics(tenant) do
    Supavisor.Monitoring.PromEx.Metrics
    |> :ets.select_delete([{{{:_, %{tenant: tenant}}, :_}, [], [true]}])
  end

  @spec set_metrics_tags() :: :ok
  def set_metrics_tags() do
    [_, host] = node() |> Atom.to_string() |> String.split("@")

    metrics_tags = %{
      region: Application.fetch_env!(:supavisor, :region),
      host: host
    }

    metrics_tags =
      case short_node_id() do
        nil -> metrics_tags
        short_alloc_id -> Map.put(metrics_tags, :short_alloc_id, short_alloc_id)
      end

    Application.put_env(:supavisor, :metrics_tags, metrics_tags)
  end

  @spec short_node_id() :: String.t() | nil
  def short_node_id() do
    with {:ok, fly_alloc_id} when is_binary(fly_alloc_id) <-
           Application.fetch_env(:supavisor, :fly_alloc_id),
         [short_alloc_id, _] <- String.split(fly_alloc_id, "-", parts: 2) do
      short_alloc_id
    else
      _ -> nil
    end
  end

  @spec get_metrics() :: String.t()
  def get_metrics() do
    def_tags =
      Application.fetch_env!(:supavisor, :metrics_tags)
      |> Enum.map_join(",", fn {k, v} -> "#{k}=\"#{v}\"" end)

    Logger.debug("Default prom tags: #{def_tags}")

    metrics =
      PromEx.get_metrics(__MODULE__)
      |> String.split("\n")
      |> Enum.map_join("\n", &parse_and_add_tags(&1, def_tags))

    Supavisor.Monitoring.PromEx.ETSCronFlusher
    |> PromEx.ETSCronFlusher.defer_ets_flush()

    metrics
  end

  @spec parse_and_add_tags(String.t(), String.t()) :: String.t()
  defp parse_and_add_tags(line, def_tags) do
    case Regex.run(~r/(?!\#)^(\w+)(?:{(.*?)})?\s*(.+)$/, line) do
      nil ->
        line

      [_, key, tags, value] ->
        tags =
          if tags == "" do
            def_tags
          else
            "#{tags},#{def_tags}"
          end

        "#{key}{#{tags}} #{value}"
    end
  end
end