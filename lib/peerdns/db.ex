defmodule PeerDNS.DB do
  use GenServer

  require Logger

  # API

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def handle_names_delta(source_id, data) do
    GenServer.call(__MODULE__, {:handle_names_delta, source_id, data})
  end

  def zone_data_update(data) do
    GenServer.call(__MODULE__, {:zone_data_update, data})
  end

  def get_owner(name) do
    case :ets.lookup(:peerdns_names, name) do
      [{^name, pk, _, _, _}] -> {:ok, pk}
      [] -> {:error, :not_found}
    end
  end

  def get_zone(name) do
    case :ets.lookup(:peerdns_names, name) do
      [{^name, pk, _weight, _version, _orig_source}] ->
        case :ets.lookup(:peerdns_zone_data, {name, pk}) do
          [{{^name, ^pk}, data}] -> {:ok, data}
          _ -> {:error, :no_data}
        end
      [] -> {:error, :not_found}
    end
  end


  # Implementation

  def init(_) do
    # The output map: {host name, public key, weight, last_version, origin source}
    :ets.new(:peerdns_names, [:set, :protected, :named_table])

    # The store map: { {name, pk}, zone_data }
    # zone_data is an instance of PeerDNS.ZoneData
    :ets.new(:peerdns_zone_data, [:set, :protected, :named_table])

    {:ok, nil}
  end

  def handle_call({:handle_names_delta, source_id, delta}, _from, state) do
    for name <- delta.removed do
      case :ets.lookup(:peerdns_names, name) do
        [{^name, pk, _, _, ^source_id}] ->
          :ets.delete(:peerdns_names, name)
          :ets.delete(:peerdons_zone_data, {name, pk})
          PeerDNS.Sync.delta_pack_remove_name(name)
        _ -> nil
      end
    end
    for {name, {pk, weight}} <- delta.added do
      case :ets.lookup(:peerdns_names, name) do
        [{^name, ^pk, old_weight, version, _}] ->
          if weight > old_weight do
            # this new info is the highest weight source
            :ets.insert(:peerdns_names, {name, pk, weight, version, source_id})
            PeerDNS.Sync.delta_pack_add_name(name, pk, weight)
          end
        [{^name, old_pk, old_weight, _, old_source}] when old_pk != pk ->
          if old_source == source_id or weight > old_weight do
            :ets.insert(:peerdns_names, {name, pk, weight, 0, source_id})
            :ets.delete(:peerdons_zone_data, {name, old_pk})
            PeerDNS.Sync.delta_pack_add_name(name, pk, weight)
          end
        [] ->
          :ets.insert(:peerdns_names, {name, pk, weight, 0, source_id})
          PeerDNS.Sync.delta_pack_add_name(name, pk, weight)
        _ -> nil
      end
    end
    {:reply, :ok, state}
  end

  def handle_call({:zone_data_update, vals}, _from, state) do
    for zd <- vals do
      pk = zd.pk
      case :ets.lookup(:peerdns_names, zd.name) do
        [{_, ^pk, weight, _ver, src}] ->
          new_ver = case :ets.lookup(:peerdns_zone_data, {zd.name, zd.pk}) do
            [{_, prev_zd}] ->
              case PeerDNS.ZoneData.update(prev_zd, zd.json, zd.signature) do
                {:ok, new_zd} ->
                  :ets.insert(:peerdns_zone_data, {{zd.name, zd.pk}, new_zd})
                  PeerDNS.Sync.delta_pack_zone_change(new_zd)
                  new_zd.version
                _ ->
                  prev_zd.version
              end
            [] ->
              :ets.insert(:peerdns_zone_data, {{zd.name, zd.pk}, zd})
              PeerDNS.Sync.delta_pack_zone_change(zd)
              zd.version
          end
          :ets.insert(:peerdns_names, {zd.name, pk, weight, new_ver, src})
        [] -> nil
      end
    end
    {:reply, :ok, state}
  end
end
