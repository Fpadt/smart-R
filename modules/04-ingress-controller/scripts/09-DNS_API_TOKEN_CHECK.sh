# Save your new token to a variable locally:
TOKEN="SYQKMzZdgBakBnPOMO5JKvWp4-2ceHQywm2oSQwT"

# Test 1: Token verification
curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
     -H "Authorization: Bearer $TOKEN" | jq '.success'

# Test 2: Zone access  
curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer $TOKEN" | \
     jq '.result[] | select(.name == "smart-r.nl" or .name == "smart-r.net") | .name'

# Test 3: DNS read access
curl -s -X GET "https://api.cloudflare.com/client/v4/zones/9b5c22216221dbf488b77d5f2980c0cd/dns_records" \
     -H "Authorization: Bearer $TOKEN" | jq '.success'