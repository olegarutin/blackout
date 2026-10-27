# frozen_string_literal: true

OE_SRC = 'https://raw.githubusercontent.com/yaroslav2901/OE_OUTAGE_DATA/main/data'
BK_SRC = 'https://raw.githubusercontent.com/Baskerville42/outage-data-ua/main/data'
ALERTS = 'https://vadimklimenko.com/map/statuses.json'
# Restriction level per oblast: 0 none, 2 hourly schedules, 3 emergency.
# This is where "emergency" comes from — the schedules carry no such flag.
ENERGY = 'https://alerts.energy/api/v1/source-registry/areas/overview'
# The transmission operator's own public channel. Its website answers
# automated clients with a Cloudflare challenge — even robots.txt — but
# this page is served to anyone, and it is where the notices originate.
UKRENERGO = 'https://t.me/s/Ukrenergo'
# One line of a public region page: when the operator last revised the
# schedule. The aggregator's llms.txt permits using its public pages for
# summarising and citing with a link, which is exactly this — one fact
# and a link. Its internal API, and the API payloads embedded in the
# page, are not used: those it declared off limits.
REGION_PAGE = 'https://alerts.energy/%s'

# Operators that publish through their own site API, read first-hand.
# The key is the region id; %s is the post slug.
OPERATOR_POSTS = {
  'Cherkasyoblenergo' => 'https://www.cherkasyoblenergo.com/api/v1/posts'
}.freeze
# Primary schedule source: explicit statuses instead of guesswork.
# The mirrors stay as a second opinion.
SHUTDOWNS = 'https://alerts.energy/api/v1/source-registry/areas/%s/shutdowns'
TTL_NEWS = 600 # новини не міняються щохвилини

# Alerts matter sooner, so they are checked every minute.
TTL_DATA  = 170
TTL_ALERT = 55

# The restriction level drives the emergency warning, and a stale one is
# worse than none: it would claim yesterday's answer about today. Past
# this age we say we do not know instead of serving the cache.
ENERGY_MAX_AGE = 1800

# A notice older than this says nothing about now.
GRID_MAX_AGE = 86_400
