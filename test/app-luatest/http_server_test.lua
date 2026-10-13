local fio = require('fio')
local json = require('json')
local socket = require('socket')
local t = require('luatest')
local treegen = require('luatest.treegen')
local justrun = require('luatest.justrun')
local http_client = require('http.client').new()
local http_server = require('http.server')
local httpd_role = require('roles.httpd')

local g = t.group()

local ssl_dir = fio.pathjoin(debug.sourcedir(),
                             '../../third_party/http/test/ssl_data')

local function free_port()
    local s = socket.tcp_server('127.0.0.1', 0, function() end)
    local port = s:name().port
    s:close()
    return port
end

local function pong(req)
    return req:render({text = 'pong'})
end

g.before_each(function(cg)
    cg.port = free_port()
    cg.uri = ('http://127.0.0.1:%d'):format(cg.port)
    cg.server = http_server.new('127.0.0.1', cg.port, {
        log_requests = false,
        log_errors = false,
    })
end)

g.after_each(function(cg)
    if cg.server:is_running() then
        cg.server:stop()
    end
    httpd_role.stop()
end)

g.test_module = function()
    t.assert_equals(table.copy(http_server), {new = http_server.new})
    for _, name in ipairs({'http.lib', 'http.sslsocket', 'http.codes',
                           'http.mime_types', 'http.version'}) do
        t.assert_not(pcall(require, name), name)
    end
end

g.test_installed_rock_wins = function()
    local dir = treegen.prepare_directory({}, {})
    treegen.write_file(dir, 'http/server.lua', "return {whoami = 'rock'}")
    treegen.write_file(dir, 'roles/httpd.lua', "return {whoami = 'rock'}")
    treegen.write_file(dir, 'main.lua', [[
        print(require('json').encode({
            require('http.server').whoami,
            require('roles.httpd').whoami,
        }))
    ]])
    local env = {LUA_PATH = dir .. '/?.lua;;'}
    local res = justrun.tarantool(dir, env, {'main.lua'})
    t.assert_equals(res.stdout, {{'rock', 'rock'}})
end

-- The bundled roles have no metadata, as other built-in modules.
g.test_roles_metadata = function()
    local file = require('internal.config.utils.file')
    t.assert_equals(file.get_module_metadata('roles.httpd'), {})
    t.assert_equals(file.get_module_metadata('roles.metrics-export'), {})
end

g.test_new_errors = function()
    local cases = {
        {'x', 'options must be a table'},
        {{app_dir = '.'}, 'unknown option app_dir'},
        {{handler = function() end}, 'unknown option handler'},
        {{display_errors = true}, 'unknown option display_errors'},
        {{log_requests = 'info'},
         'option log_requests must be a boolean or a function'},
        {{idle_timeout = 'x'}, 'idle_timeout must be a number'},
        {{ssl_cert_file = '/no/such/file'}, 'not exists'},
    }
    for _, case in ipairs(cases) do
        t.assert_error_msg_contains(case[2], http_server.new, '127.0.0.1', 0,
                                    case[1])
    end
end

g.test_server = function(cg)
    for _, field in ipairs({'routes', 'iroutes', 'options', 'hooks',
                            'is_run', 'tcp_server_f', 'internal'}) do
        t.assert_equals(cg.server[field], nil, field)
    end
    t.assert_equals(cg.server.host, '127.0.0.1')
    t.assert_equals(cg.server.port, cg.port)

    t.assert_not(cg.server:is_running())
    t.assert_is(cg.server:start(), cg.server)
    t.assert(cg.server:is_running())
    t.assert_error_msg_contains('already running', cg.server.start,
                                cg.server)
    t.assert_error_msg_contains('Use server:method(...)', cg.server.start)
    t.assert_is(cg.server:stop(), cg.server)
    t.assert_not(cg.server:is_running())
end

g.test_route_errors = function(cg)
    local cases = {
        {'x', pong, 'route options must be a table'},
        {{path = '/a', file = 'a.html'}, pong, 'unknown route option file'},
        {{path = '/a', template = 'a'}, pong,
         'unknown route option template'},
        {{path = '/a'}, 'module#action', 'route handler must be a function'},
        {{path = '/a'}, nil, 'route handler must be a function'},
        {{path = '/a', method = 'OPTIONS'}, pong,
         'invalid route method OPTIONS'},
        {{path = 42}, pong, 'invalid route path 42'},
        {{path = '/a%d'}, pong, 'invalid route path /a%d'},
        {{path = '/a(b'}, pong, 'invalid route path /a(b'},
        {{path = '/a/*'}, pong, 'invalid route path /a/*'},
        {{path = '/a', name = 1}, pong, 'route name must be a string'},
    }
    for _, case in ipairs(cases) do
        t.assert_error_msg_contains(case[3], cg.server.route, cg.server,
                                    case[1], case[2])
    end
    cg.server:route({path = '/a', name = 'a'}, pong)
    t.assert_error_msg_contains("Route with name 'a' is already exists",
                                cg.server.route, cg.server,
                                {path = '/b', name = 'a'}, pong)
end

g.test_routes = function(cg)
    t.assert_is(cg.server:route({path = '/users/:id', name = 'user'}, pong),
                cg.server)
    t.assert(cg.server:has_route('user'))
    t.assert_not(cg.server:has_route('other'))
    t.assert_equals(cg.server:url_for('user', {id = 1}, {a = 'b'}),
                    '/users/1?a=b')
    cg.server:delete('user')
    t.assert_not(cg.server:has_route('user'))

    cg.server:start()
    t.assert_equals(http_client:get(cg.uri .. '/users/1').status, 404)
end

g.test_request = function(cg)
    cg.server:route({path = '/users/:id', name = 'user'}, function(req)
        return req:render({json = {
            method = req.method,
            path = req.path,
            query = req.query,
            header = req.headers['x-test'],
            peer = req.peer.host,
            endpoint = req.endpoint,
            id = req:stash('id'),
            q = req:query_param('q'),
            param = req:param('q'),
            url = req:url_for('user', {id = 2}),
            hidden = {req.s == nil, req.httpd == nil, req.proto == nil},
        }})
    end)
    cg.server:start()

    local resp = http_client:get(cg.uri .. '/users/1?q=x',
                                 {headers = {['X-Test'] = 'yes'}})
    t.assert_equals(resp.status, 200)
    t.assert_equals(json.decode(resp.body), {
        method = 'GET',
        path = '/users/1',
        query = 'q=x',
        header = 'yes',
        peer = '127.0.0.1',
        endpoint = {path = '/users/:id', method = 'ANY', name = 'user'},
        id = '1',
        q = 'x',
        param = 'x',
        url = '/users/2',
        hidden = {true, true, true},
    })
end

g.test_request_body = function(cg)
    cg.server:route({path = '/json', method = 'POST'}, function(req)
        return req:render({json = req:json()})
    end)
    cg.server:route({path = '/form', method = 'POST'}, function(req)
        return req:render({json = {
            a = req:post_param('a'),
            read_cached = req:read_cached(),
            read = req:read(),
        }})
    end)
    cg.server:start()

    local resp = http_client:post(cg.uri .. '/json', json.encode({a = 1}), {
        headers = {['content-type'] = 'application/json'},
    })
    t.assert_equals(json.decode(resp.body), {a = 1})
    resp = http_client:post(cg.uri .. '/form', 'a=b', {
        headers = {['content-type'] = 'application/x-www-form-urlencoded'},
    })
    t.assert_equals(json.decode(resp.body),
                    {a = 'b', read_cached = 'a=b', read = 'a=b'})
end

g.test_cookie_and_redirect = function(cg)
    cg.server:route({path = '/cookie'}, function(req)
        local resp = req:render({text = req:cookie('a')})
        resp:setcookie({name = 'b', value = 'c', path = '/'})
        return resp
    end)
    cg.server:route({path = '/target', name = 'target'}, pong)
    cg.server:route({path = '/redirect'}, function(req)
        return req:redirect_to('target')
    end)
    cg.server:start()

    local resp = http_client:get(cg.uri .. '/cookie',
                                 {headers = {cookie = 'a=x'}})
    t.assert_equals(resp.body, 'x')
    t.assert_str_contains(resp.headers['set-cookie'], 'b=c;path=/')
    resp = http_client:get(cg.uri .. '/redirect', {follow_location = false})
    t.assert_equals(resp.status, 302)
    t.assert_equals(resp.headers['location'], '/target')
end

g.test_responses = function(cg)
    local handlers = {
        ['/nil'] = function() end,
        ['/headers'] = function()
            return {status = 201, headers = {['x-a'] = {'1', '2'}}}
        end,
        ['/bad_status'] = function() return {status = '200'} end,
        ['/bad_headers'] = function() return {headers = 'x'} end,
        ['/bad_body'] = function() return {body = function() end} end,
        ['/detached'] = function() return 101 end,
        ['/error'] = function() error('boom') end,
        ['/template'] = function(req) return req:render({template = 'x'}) end,
    }
    for path, handler in pairs(handlers) do
        cg.server:route({path = path}, handler)
    end
    cg.server:start()

    local resp = http_client:get(cg.uri .. '/nil')
    t.assert_equals(resp.status, 200)
    t.assert_equals(resp.body or '', '')
    resp = http_client:get(cg.uri .. '/headers')
    t.assert_equals(resp.status, 201)
    t.assert_equals(resp.headers['x-a'], '1,2')
    for _, path in ipairs({'/bad_status', '/bad_headers', '/bad_body',
                           '/detached', '/error', '/template'}) do
        t.assert_equals(http_client:get(cg.uri .. path).status, 500, path)
    end
end

g.test_no_static_files = function(cg)
    local dir = treegen.prepare_directory({}, {})
    treegen.write_file(dir, 'public/file.txt', 'data')
    local cwd = fio.cwd()
    fio.chdir(dir)
    cg.server:start()
    local resp = http_client:get(cg.uri .. '/file.txt')
    fio.chdir(cwd)
    t.assert_equals(resp.status, 404)
end

g.test_unix_socket = function()
    local path = fio.pathjoin(treegen.prepare_directory({}, {}), 'http.sock')
    local server = http_server.new('unix/', path, {log_requests = false})
    server:route({path = '/ping'}, pong)
    server:start()
    local resp = http_client:get('http://localhost/ping', {unix_socket = path})
    server:stop()
    t.assert_equals(resp.body, 'pong')
end

g.test_tls = function(cg)
    local server = http_server.new('localhost', cg.port, {
        log_requests = false,
        ssl_cert_file = fio.pathjoin(ssl_dir, 'server.crt'),
        ssl_key_file = fio.pathjoin(ssl_dir, 'server.key'),
    })
    server:route({path = '/ping'}, pong)
    server:start()
    local resp = http_client:get(
        ('https://localhost:%d/ping'):format(cg.port),
        {ca_file = fio.pathjoin(ssl_dir, 'ca.crt')})
    server:stop()
    t.assert_equals(resp.body, 'pong')
end

g.test_roles_httpd = function(cg)
    local cfg = {default = {listen = cg.port}}
    httpd_role.apply(cfg)
    local server = httpd_role.get_server()
    t.assert_equals(server.options, nil)
    server:route({path = '/ping', name = 'ping'}, pong)
    local resp = http_client:get(cg.uri .. '/ping')
    t.assert_equals(resp.body, 'pong')

    -- The server is kept while its options are the same.
    httpd_role.apply(cfg)
    t.assert_is(httpd_role.get_server(), server)

    -- Changed options give a new server.
    cfg.default.log_requests = 'debug'
    httpd_role.apply(cfg)
    t.assert_is_not(httpd_role.get_server(), server)
    t.assert_not(server:is_running())
    t.assert(httpd_role.get_server():is_running())

    httpd_role.apply({})
    t.assert_equals(httpd_role.get_server(), nil)
end
