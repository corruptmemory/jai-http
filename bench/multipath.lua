-- wrk driver for examples/multipath.jai — rotates each request across all 10 routes
-- (static / param / nested-param / param-leaf / wildcard / versioned), so load spreads
-- evenly instead of hammering a single path.
--
-- Usage (build + run the example first):
--   ~/jai/jai/bin/jai-linux first.jai - multipath -release
--   ./build_release/multipath &
--   wrk -t16 -c1000 -d10s -s bench/multipath.lua http://localhost:9090
--
-- Each wrk thread keeps its own rotating index, which is fine — load still spreads.

local paths = {
  "/",
  "/health",
  "/api/status",
  "/api/users",
  "/api/users/42",          -- /api/users/:id
  "/api/users/42/posts",    -- /api/users/:id/posts
  "/api/posts/99",          -- /api/posts/:id
  "/static/css/app.css",    -- /static/*filepath
  "/api/v1/info",
  "/api/v2/info",
}
local n = #paths
local i = 0

request = function()
  i = i + 1
  if i > n then i = 1 end
  return wrk.format("GET", paths[i])
end
