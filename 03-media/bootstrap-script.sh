#!/bin/sh
# Idempotent post-deploy wiring for SABnzbd/Sonarr/Radarr. Safe to re-run.
set -eu

wait_for_file() {
  i=0
  while [ ! -f "$1" ]; do
    i=$((i + 1))
    [ "$i" -gt 120 ] && { echo "timeout waiting for $1"; exit 1; }
    sleep 2
  done
}

wait_for_http() {
  i=0
  until curl -sf "$1" -o /dev/null; do
    i=$((i + 1))
    [ "$i" -gt 120 ] && { echo "timeout waiting for $1"; exit 1; }
    sleep 2
  done
}

wait_for_file /sab-config/sabnzbd.ini
wait_for_file /sonarr-config/config.xml
wait_for_file /radarr-config/config.xml
wait_for_file /prowlarr-config/config.xml

echo "Creating shared library folders..."
mkdir -p /data/media/tv /data/media/movies /data/downloads/complete /data/downloads/incomplete
chown -R 1000:1000 /data

SAB_KEY=$(grep -m1 '^api_key' /sab-config/sabnzbd.ini | sed 's/^api_key = //' | tr -d '\r')
SONARR_KEY=$(grep -oE '<ApiKey>[^<]+' /sonarr-config/config.xml | sed 's/<ApiKey>//')
RADARR_KEY=$(grep -oE '<ApiKey>[^<]+' /radarr-config/config.xml | sed 's/<ApiKey>//')
PROWLARR_KEY=$(grep -oE '<ApiKey>[^<]+' /prowlarr-config/config.xml | sed 's/<ApiKey>//')

SAB_URL="http://sabnzbd.media.svc.cluster.local:8080"
SONARR_URL="http://sonarr.media.svc.cluster.local:8989"
RADARR_URL="http://radarr.media.svc.cluster.local:7878"
PROWLARR_URL="http://prowlarr.media.svc.cluster.local:9696"

wait_for_http "$SAB_URL/api?mode=version"
wait_for_http "$SONARR_URL/ping"
wait_for_http "$RADARR_URL/ping"
wait_for_http "$PROWLARR_URL/ping"

echo "Configuring SABnzbd..."
curl -sf "$SAB_URL/api?mode=set_config&section=misc&keyword=download_dir&value=/data/downloads/incomplete&apikey=$SAB_KEY&output=json" >/dev/null
curl -sf "$SAB_URL/api?mode=set_config&section=misc&keyword=complete_dir&value=/data/downloads/complete&apikey=$SAB_KEY&output=json" >/dev/null
curl -sf "$SAB_URL/api?mode=set_config&section=misc&keyword=host_whitelist&value=$SAB_HOST_WHITELIST&apikey=$SAB_KEY&output=json" >/dev/null
curl -sf "$SAB_URL/api?mode=set_config&section=categories&name=tv&dir=tv&apikey=$SAB_KEY&output=json" >/dev/null
curl -sf "$SAB_URL/api?mode=set_config&section=categories&name=movies&dir=movies&apikey=$SAB_KEY&output=json" >/dev/null

echo "Configuring Sonarr..."
if ! curl -sf "$SONARR_URL/api/v3/downloadclient" -H "X-Api-Key: $SONARR_KEY" | grep -q '"name":[[:space:]]*"SABnzbd"'; then
  curl -sf -X POST "$SONARR_URL/api/v3/downloadclient" -H "X-Api-Key: $SONARR_KEY" -H "Content-Type: application/json" \
    -d "{\"enable\":true,\"protocol\":\"usenet\",\"priority\":1,\"name\":\"SABnzbd\",\"implementation\":\"Sabnzbd\",\"configContract\":\"SabnzbdSettings\",\"fields\":[{\"name\":\"host\",\"value\":\"sabnzbd.media.svc.cluster.local\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"apiKey\",\"value\":\"$SAB_KEY\"},{\"name\":\"category\",\"value\":\"tv\"},{\"name\":\"useSsl\",\"value\":false}]}" >/dev/null
fi
if ! curl -sf "$SONARR_URL/api/v3/rootfolder" -H "X-Api-Key: $SONARR_KEY" | grep -q '"path":[[:space:]]*"/data/media/tv"'; then
  curl -sf -X POST "$SONARR_URL/api/v3/rootfolder" -H "X-Api-Key: $SONARR_KEY" -H "Content-Type: application/json" -d '{"path":"/data/media/tv"}' >/dev/null
fi

echo "Configuring Radarr..."
if ! curl -sf "$RADARR_URL/api/v3/downloadclient" -H "X-Api-Key: $RADARR_KEY" | grep -q '"name":[[:space:]]*"SABnzbd"'; then
  curl -sf -X POST "$RADARR_URL/api/v3/downloadclient" -H "X-Api-Key: $RADARR_KEY" -H "Content-Type: application/json" \
    -d "{\"enable\":true,\"protocol\":\"usenet\",\"priority\":1,\"name\":\"SABnzbd\",\"implementation\":\"Sabnzbd\",\"configContract\":\"SabnzbdSettings\",\"fields\":[{\"name\":\"host\",\"value\":\"sabnzbd.media.svc.cluster.local\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"apiKey\",\"value\":\"$SAB_KEY\"},{\"name\":\"movieCategory\",\"value\":\"movies\"},{\"name\":\"useSsl\",\"value\":false}]}" >/dev/null
fi
if ! curl -sf "$RADARR_URL/api/v3/rootfolder" -H "X-Api-Key: $RADARR_KEY" | grep -q '"path":[[:space:]]*"/data/media/movies"'; then
  curl -sf -X POST "$RADARR_URL/api/v3/rootfolder" -H "X-Api-Key: $RADARR_KEY" -H "Content-Type: application/json" -d '{"path":"/data/media/movies"}' >/dev/null
fi

echo "Configuring Prowlarr..."
if ! curl -sf "$PROWLARR_URL/api/v1/applications" -H "X-Api-Key: $PROWLARR_KEY" | grep -q '"name":[[:space:]]*"Sonarr"'; then
  curl -sf -X POST "$PROWLARR_URL/api/v1/applications" -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
    -d "{\"syncLevel\":\"fullSync\",\"name\":\"Sonarr\",\"implementation\":\"Sonarr\",\"implementationName\":\"Sonarr\",\"configContract\":\"SonarrSettings\",\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"$PROWLARR_URL\"},{\"name\":\"baseUrl\",\"value\":\"$SONARR_URL\"},{\"name\":\"apiKey\",\"value\":\"$SONARR_KEY\"},{\"name\":\"syncCategories\",\"value\":[5000,5010,5020,5030,5040,5045,5050,5090]}],\"tags\":[]}" >/dev/null
fi
if ! curl -sf "$PROWLARR_URL/api/v1/applications" -H "X-Api-Key: $PROWLARR_KEY" | grep -q '"name":[[:space:]]*"Radarr"'; then
  curl -sf -X POST "$PROWLARR_URL/api/v1/applications" -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
    -d "{\"syncLevel\":\"fullSync\",\"name\":\"Radarr\",\"implementation\":\"Radarr\",\"implementationName\":\"Radarr\",\"configContract\":\"RadarrSettings\",\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"$PROWLARR_URL\"},{\"name\":\"baseUrl\",\"value\":\"$RADARR_URL\"},{\"name\":\"apiKey\",\"value\":\"$RADARR_KEY\"},{\"name\":\"syncCategories\",\"value\":[2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090]}],\"tags\":[]}" >/dev/null
fi

echo "Done."
