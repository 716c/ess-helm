{{- /*
Copyright 2024 New Vector Ltd

SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
*/ -}}

{{- $root := .root -}}
{{- with required "haproxy.cfg.tpl missing context" .context -}}

frontend synapse-http-in
  bind *:8008

  # same as http log, with %Th (handshake time)
  log-format "%ci:%cp [%tr] %ft %b/%s %Th/%TR/%Tw/%Tc/%Tr/%Ta %ST %B %CC %CS %tsc %ac/%fc/%bc/%sc/%rc %sq/%bq %hr %hs %{+Q}r"

  capture request header Host len 32
  capture request header Referer len 200
  capture request header User-Agent len 200

  # before we change the 'src', stash it in a session variable
  http-request set-var(sess.orig_src) src if !{ var(sess.orig_src) -m found }

  # in case this is not the first request on the connection, restore the
  # 'src' to the original, in case we fail to parse the x-f-f header.
  http-request set-src var(sess.orig_src)

  # Traditionally do this only for traffic from some limited IP addreses
  # but the incoming router being what it is, means we have no fixed IP here.
  http-request set-src hdr(x-forwarded-for)

  # We always add a X-Forwarded-For header (clobbering any existing
  # headers).
  http-request set-header X-Forwarded-For %[src]

  # Ingresses by definition run on both 80 & 443 and there's no customising of that
  # It is up to the ingress controller and any annotations provided to it whether
  # it sets any additional headers or not or whether it redirects http -> https
  # We don't have control (or even visiblity) on what the ingress controller is or does
  # So we can't guarantee the header is present
  # https is a more sensible default than http for the missing header as we force public_baseurl to https
  http-request set-header X-Forwarded-Proto https if !{ hdr(X-Forwarded-Proto) -m found }
  http-request set-var(txn.x_forwarded_proto) hdr(x-forwarded-proto)
  http-response add-header Strict-Transport-Security max-age=31536000 if { var(txn.x_forwarded_proto) -m str -i "https" }

  # If we get here then we want to proxy everything to synapse or a worker.

  # try to extract a useful access token from either the auth header or a
  # query-param
  http-request set-var(req.access_token) urlp("access_token") if { urlp("access_token") -m found }
  http-request set-var(req.access_token) req.fhdr(Authorization),word(2," ") if { hdr_beg("Authorization") -i "Bearer " }

  # We also need a http header format to allow us to loadbalance and make decisions:
  http-request set-header X-Access-Token %[var(req.access_token)]

  # Disable Google FLoC
  http-response set-header Permissions-Policy "interest-cohort=()"

  # Load the backend from one of the map files.
  acl has_get_map path -m reg -M -f /synapse/path_map_file_get

  http-request set-var(req.backend) path,map_reg(/synapse/path_map_file_get,main) if has_get_map METH_GET
  http-request set-var(req.backend) path,map_reg(/synapse/path_map_file,main) unless { var(req.backend) -m found }

  use_backend return_204 if { method OPTIONS }

{{- range .ingress.additionalPaths -}}
{{- if eq .availability "internally_and_externally" }}

{{- $additionalPathId := printf "%s_%s" .service.name (.service.port.name | default .service.port.number) }}
  acl is_svc_{{ $additionalPathId }} path_beg {{ .path }}
  use_backend synapse-be_{{ $additionalPathId }} if is_svc_{{ $additionalPathId }}
{{- end }}
{{- end }}
{{- if dig "initial-synchrotron" "enabled" false .workers }}

  # special synchrotron backend for initialsyncs
  acl is_sync path -m reg ^/_matrix/client/(r0|v3)/sync$
  acl is_sync path -m reg ^/_matrix/client/(api/v1|r0|v3)/events$
  use_backend synapse-initial-synchrotron if is_sync { urlp("full_state") -m str true }
  use_backend synapse-initial-synchrotron if is_sync !{ urlp("since") -m found } !{ urlp("from") -m found }
{{- end }}

  use_backend synapse-%[var(req.backend)]

backend synapse-main
  default-server maxconn 250
  # Use DNS SRV service discovery on the headless service
  server-template main 1 _synapse-http._tcp.{{ $root.Release.Name }}-synapse-main.{{ $root.Release.Namespace }}.svc.cluster.local resolvers kubedns init-addr none

{{- range $workerType, $workerDetails := (include "element-io.synapse.enabledWorkers" (dict "root" $root)) | fromJson }}
{{- if include "element-io.synapse.process.hasHttp" (dict "root" $root "context" $workerType) }}

backend synapse-{{ $workerType }}
{{- if eq $workerType "event-creator" }}
  # We want to balance based on the room, so try and pull it out of the path
  http-request set-header X-Matrix-Room %[path]
  http-request replace-header X-Matrix-Room rooms/([^/]+) \1
  http-request replace-header X-Matrix-Room join/([^/]+) \1

  balance hdr(X-Matrix-Room)

{{- else if eq $workerType "federation-inbound" }}
  # We balance by source IP so the same origin servers go to the same worker.
  # That should be enough to ensure that transactions from the same origin go
  # to the same worker, unless they change IP, in which case its not actually
  # the end of the world if we process the same transaction twice.
  balance source

{{- else if eq $workerType "federation-reader" }}
  # we balance by URI principally so that identical state_ids requests go to
  # the same worker. They are expensive so we want to avoid duplicate work;
  # on the other hand if we don't include the URI params then all the
  # requests for a given room go to one worker, which tends to send it into
  # a death spiral.
  balance uri whole

{{- else if eq $workerType "initial-synchrotron" }}
  # increase the server timeout, as it can take a long time to generate and
  # return the initial sync.
  timeout server 180s

  # Balance on hash of access token
  balance hdr(X-Access-Token)

  # limit the number of concurrent requests to each synchrotron,
  # to stop the reactor tick time rocketing
  default-server maxconn 50

{{- else if has $workerType (list "sliding-sync" "synchrotron") }}
  # Balance on the hash of the access token.
  # When using stick tables, the stickiness only takes effect once the backend
  # has responded at least once. If a user keeps timing out on their first
  # incremental sync in a while, then they will keep 'bouncing' around
  # different synchrotrons, preventing their sync from making progress.
  #
  # We can still use stick tables to ensure that once a client gets assigned
  # to a Synchrotron it stays on that worker, allowing us to rebalance the
  # pool without moving existing sessions.
  #
  # If the header doesn't exist it will round robin requests,
  # though in that case they should all just be 4xx'd due
  # to lack of an access token.
  balance hdr(X-Access-Token)

  # synchrotrons are long-polled, so we need to allow many
  # concurrent connections.
  default-server maxconn 2000

  # if we *do* hit the limit, it's probably better we shed further
  # requests quickly than let them queue up on the haproxy.
  timeout queue 5s

{{- end }}
{{- $maxInstances := ternary 1 20 (not (empty (include "element-io.synapse.process.isSingle" (dict "root" $root "context" $workerType)))) }}
{{- $workerTypeName := include "element-io.synapse.process.workerTypeName" (dict "root" $root "context" $workerType) }}
  # Use DNS SRV service discovery on the headless service
  server-template {{ $workerTypeName }} {{ $maxInstances }} _synapse-http._tcp.{{ $root.Release.Name }}-synapse-{{ $workerTypeName }}.{{ $root.Release.Namespace }}.svc.cluster.local resolvers kubedns init-addr none
{{- end }}
{{- end }}

{{- range .ingress.additionalPaths -}}
{{- if eq .availability "internally_and_externally" }}
{{- $additionalPathId := printf "%s_%s" .service.name (.service.port.name | default .service.port.number) }}
backend synapse-be_{{ $additionalPathId }}
{{- if .service.port.name }}
  server-template {{ $additionalPathId }} 10 _{{ .service.port.name }}._tcp.{{ .service.name }}.{{ $root.Release.Namespace }}.svc.cluster.local resolvers kubedns init-addr none
{{- else }}
  server-template {{ $additionalPathId }} 10 _{{ .service.name }}.{{ $root.Release.Namespace }}.svc.cluster.local:{{ .service.port.number }} resolvers kubedns init-addr none
{{- end }}
{{- end }}
{{- end }}

{{- end -}}
