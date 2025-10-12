#!/bin/bash
curl -k \
  -X GET \
  http://10.0.0.2:50000/machine.Status \
  -H "Authorization: Bearer $(cat /path/to/talosconfig | yq '.context.client.token')" \
  -H "Content-Type: application/json"
