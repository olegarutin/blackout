OE_SRC = 'https://raw.githubusercontent.com/yaroslav2901/OE_OUTAGE_DATA/main/data'
BK_SRC = 'https://raw.githubusercontent.com/Baskerville42/outage-data-ua/main/data'
ALERTS = 'https://vadimklimenko.com/map/statuses.json'
# Restriction level per oblast: 0 none, 2 hourly schedules, 3 emergency.
# This is where "emergency" comes from — the schedules carry no such flag.
ENERGY = 'https://alerts.energy/api/v1/source-registry/areas/overview'
# The grid operator's headline notice: the schedule says when, this says
# why — an attack, a deficit, repairs.
NOTICE = 'https://alerts.energy/api/v1/notices'
# Primary schedule source: explicit statuses instead of guesswork.
# The mirrors stay as a second opinion.
SHUTDOWNS = 'https://alerts.energy/api/v1/source-registry/areas/%s/shutdowns'
TTL_NEWS = 600 # новини не міняються щохвилини

# Alerts matter sooner, so they are checked every minute.
TTL_DATA  = 170
TTL_ALERT = 55

