# on the first startup exec into the couchdb pod and execute following:
export hostname=localhost:5984 ; export username=$COUCHDB_USER ; export password=$COUCHDB_PASSWORD ; curl -s https://raw.githubusercontent.com/vrtmrz/obsidian-livesync/main/utils/couchdb/couchdb-init.sh | bash

# Once done and couchdb is reachable via internet, execute following on a local machine:
export hostname=https://obsidian.<DOMAIN_NAME>
export database=obsidiannotes
export passphrase=<RANDOM STRING>
export username=$COUCHDB_USER
export password=$COUCHDB_PASSWORD
deno run -A https://raw.githubusercontent.com/vrtmrz/obsidian-livesync/main/utils/flyio/generate_setupuri.ts
