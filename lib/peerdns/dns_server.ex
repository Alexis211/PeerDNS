defmodule PeerDNS.DNSServer do
  @behaviour DNS.Server
  use DNS.Server

  def handle(record, _cl) do
    Logger.info(fn -> "#{inspect(record)}" end)
    query = hd(record.qdlist)

    result =
      case query.type do
        :a -> {127, 0, 0, 1}
        :cname -> 'your.domain.com'
        :txt -> ['your txt value']
        _ -> nil
      end

    resource = %DNS.Resource{
      domain: query.domain,
      class: query.class,
      type: query.type,
      ttl: 0,
      data: result
    }

    %{record | anlist: [resource], header: %{record.header | qr: true}}
  end
end