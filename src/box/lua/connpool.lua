local fiber = require('fiber')
local clock = require('clock')
local config = require('config')
local checks = require('checks')
local fun = require('fun')
local netbox = require('net.box')

local WATCHER_DELAY = 0.1
local WATCHER_TIMEOUT = 10

local connections = {}

local function is_connection_valid(conn, opts)
    if conn == nil or conn.state == 'error' or conn.state == 'closed' then
        return false
    end
    assert(type(opts) == 'table')
    local conn_opts = conn.opts or {}
    if opts.fetch_schema ~= false and conn_opts.fetch_schema == false then
        return false
    end
    return true
end

local connection_mode_update_cond = nil
local function connect(instance_name, opts)
    if not connection_mode_update_cond then
        connection_mode_update_cond = fiber.cond()
    end

    checks('string', {
        connect_timeout = '?number',
        wait_connected = '?boolean',
        fetch_schema = '?boolean',
    })
    opts = opts or {}

    local conn = connections[instance_name]
    if not is_connection_valid(conn, opts) then
        local uri = config:instance_uri('peer', {instance = instance_name})
        if uri == nil then
            local err = 'No suitable URI provided for instance %q'
            error(err:format(instance_name), 0)
        end

        local conn_opts = {
            connect_timeout = opts.connect_timeout,
            wait_connected = false,
            fetch_schema = opts.fetch_schema,
        }
        local ok, res = pcall(netbox.connect, uri, conn_opts)
        if not ok then
            local msg = 'Unable to connect to instance %q: %s'
            error(msg:format(instance_name, res.message), 0)
        end
        conn = res
        connections[instance_name] = conn
        local function mode(conn)
            if conn.state == 'active' then
                return conn._mode
            end
            return nil
        end
        conn.mode = mode
        local function watch_status(_key, value)
            conn._mode = value.is_ro and 'ro' or 'rw'
            connection_mode_update_cond:broadcast()
        end
        conn:watch('box.status', watch_status)
    end

    -- If opts.wait_connected is not false we wait until the connection is
    -- established or an error occurs (including a timeout error).
    if opts.wait_connected ~= false and conn:wait_connected() == false then
        local msg = 'Unable to connect to instance %q: %s'
        error(msg:format(instance_name, conn.error), 0)
    end
    return conn
end

local function is_candidate_connected(candidate)
    local conn = connections[candidate]
    return conn and conn.state == 'active' and conn:mode() ~= nil
end

-- Checks whether the candidate has responded with success or
-- with an error.
local function is_candidate_checked(candidate)
    local conn = connections[candidate]

    return not conn or
           is_candidate_connected(candidate) or
           conn.state == 'error' or
           conn.state == 'closed'
end

-- This method connects to all of the specified instances
-- and returns the set of successfully connected ones.
local function acquire_all_instances(instance_names)
    if next(instance_names) == nil then return {} end

    local delay = WATCHER_DELAY
    local connect_deadline = clock.monotonic() + WATCHER_TIMEOUT

    for _, instance_name in pairs(instance_names) do
        pcall(connect, instance_name, {
            wait_connected = false,
            connect_timeout = WATCHER_TIMEOUT
        })
    end

    assert(connection_mode_update_cond ~= nil)

    local connected_candidates = {}
    while clock.monotonic() < connect_deadline do
        connected_candidates = fun.iter(instance_names)
            :filter(is_candidate_connected)
            :totable()

        local all_checked = fun.iter(instance_names)
            :all(is_candidate_checked)

        if all_checked then
            return connected_candidates
        end

        connection_mode_update_cond:wait(delay)
    end
    return connected_candidates
end

-- The method starts connecting to the specified set of
-- instances and returns the first one available matching
-- the specified dynamic requirements.
--
-- Note: if the specified mode is nil the connection
-- returned may not have the `mode()` method available.
local function acquire_any_instance(instance_names, opts)
    assert(type(opts) == 'table')
    assert(opts.mode == nil or opts.mode == 'ro' or opts.mode == 'rw')
    local time_connect_end = clock.monotonic() + WATCHER_TIMEOUT

    for _, instance_name in pairs(instance_names) do
        pcall(connect, instance_name, {
            wait_connected = false,
            connect_timeout = WATCHER_TIMEOUT
        })
    end

    while clock.monotonic() < time_connect_end do
        local all_checked = true

        for _, instance_name in ipairs(instance_names) do
            local conn = connections[instance_name]
            if is_connection_valid(conn, {}) and
               (opts.mode == nil or opts.mode == conn:mode()) then
                return conn
            end

            if not is_candidate_checked(instance_name) then
                all_checked = false
            end
        end

        -- Return early if all of the instances don't match the
        -- requirements or unavailable.
        if all_checked then
            break
        end

        connection_mode_update_cond:wait(WATCHER_DELAY)
    end
    return nil
end

local function is_group_match(expected_groups, present_group)
    if expected_groups == nil or next(expected_groups) == nil then
        return true
    end
    for _, group in pairs(expected_groups) do
        if group == present_group then
            return true
        end
    end
    return false
end

local function is_replicaset_match(expected_replicasets, present_replicaset)
    if expected_replicasets == nil or next(expected_replicasets) == nil then
        return true
    end
    for _, replicaset in pairs(expected_replicasets) do
        if replicaset == present_replicaset then
            return true
        end
    end
    return false
end

local function is_instance_match(expected_instances, present_instance)
    if expected_instances == nil or next(expected_instances) == nil then
        return true
    end
    for _, instance in pairs(expected_instances) do
        if instance == present_instance then
            return true
        end
    end
    return false
end

local function is_roles_match(expected_roles, present_roles)
    if expected_roles == nil or next(expected_roles) == nil then
        return true
    end
    if present_roles == nil or next(present_roles) == nil then
        return false
    end

    local roles = {}
    for _, present_role_name in pairs(present_roles) do
        roles[present_role_name] = true
    end
    for _, expected_role_name in pairs(expected_roles) do
        if roles[expected_role_name] == nil then
            return false
        end
    end
    return true
end

local function is_labels_match(expected_labels, present_labels)
    if expected_labels == nil or next(expected_labels) == nil then
        return true
    end
    if present_labels == nil or next(present_labels) == nil then
        return false
    end

    for label, value in pairs(expected_labels) do
        if present_labels[label] ~= value then
            return false
        end
    end
    return true
end

local function is_candidate_match_static(names, opts)
    assert(opts ~= nil and type(opts) == 'table')
    local get_opts = {instance = names.instance_name}
    return is_group_match(opts.groups, names.group_name) and
           is_replicaset_match(opts.replicasets, names.replicaset_name) and
           is_instance_match(opts.instances, names.instance_name) and
           is_roles_match(opts.roles, config:get('roles', get_opts)) and
           is_roles_match(opts.sharding_roles,
                          config:get('sharding.roles', get_opts)) and
           is_labels_match(opts.labels, config:get('labels', get_opts))
end

local function is_mode_match(mode, instance_name)
    if mode == nil then return true end
    -- The instance should be alive to match its mode.
    assert(mode == 'ro' or mode == 'rw')

    local conn = connections[instance_name]
    assert(conn ~= nil)
    return conn:mode() == mode
end

local function is_candidate_match_dynamic(instance_name, opts)
    assert(opts ~= nil and type(opts) == 'table')
    return is_mode_match(opts.mode, instance_name)
end

local function filter(opts)
    checks({
        groups = '?table',
        replicasets = '?table',
        instances = '?table',
        labels = '?table',
        roles = '?table',
        sharding_roles = '?table',
        mode = '?string',
        skip_connection_check = '?boolean'
    })
    opts = opts or {}

    if opts.mode ~= nil and opts.mode ~= 'ro' and opts.mode ~= 'rw' then
        local msg = 'Expected nil, "ro" or "rw", got "%s"'
        error(msg:format(opts.mode), 0)
    end

    if opts.skip_connection_check and opts.mode ~= nil then
        local msg = 'Filtering by mode "%s" requires the connection ' ..
                    'check disabled by the "skip_connection_check" option'
        error(msg:format(opts.mode), 0)
    end

    if opts.sharding_roles ~= nil then
        for _, sharding_role in ipairs(opts.sharding_roles) do
            if sharding_role == 'rebalancer' then
               error('Filtering by the \"rebalancer\" role is not supported',
                     0)
            elseif sharding_role ~= 'storage' and
               sharding_role ~= 'router' then
               local msg = 'Unknown sharding role \"%s\" in '..
                           'connpool.filter() call. Expected one of the '..
                           '\"storage\", \"router\"'
               error(msg:format(sharding_role), 0)
            end
        end
    end
    local static_opts = {
        groups = opts.groups,
        replicasets = opts.replicasets,
        instances = opts.instances,
        labels = opts.labels,
        roles = opts.roles,
        sharding_roles = opts.sharding_roles
    }
    local dynamic_opts = {
        mode = opts.mode,
    }

    -- First, select candidates using the information from the config.
    local static_candidates = {}
    for instance_name, names in pairs(config:instances()) do
        if is_candidate_match_static(names, static_opts) then
            table.insert(static_candidates, instance_name)
        end
    end

    -- Return if the connection check isn't needed.
    if opts.skip_connection_check then
        return static_candidates
    end

    -- Filter the remaining candidates after connecting to them.
    --
    -- The acquire_all_instances() call returns quickly if it
    -- receives empty table as an argument.
    local connected_candidates = acquire_all_instances(static_candidates)
    local dynamic_candidates = {}
    for _, instance_name in pairs(connected_candidates) do
        if is_candidate_match_dynamic(instance_name, dynamic_opts) then
            table.insert(dynamic_candidates, instance_name)
        end
    end
    return dynamic_candidates
end

local function select_connection_from_list(instances, opts)
    assert(opts ~= nil and type(opts) == 'table')

    if opts.prefer_local then
        local local_instance = box.info.name

        for _, instance in ipairs(instances) do
            if instance == local_instance then
                -- This connect is almomst always quick and successful,
                -- so it's being waited. Though it can fail e.g. due to
                -- the FD limit. That's why it still should be checked.
                local ok, conn = pcall(connect, local_instance,
                                       { wait_connected = true })

                -- To use the local connection, the connect() call
                -- should be ok, if the mode is specified the
                -- connection mode should exist (thus, this select
                -- may be false-negative) and the candidate should
                -- match dynamic options.
                if ok and (opts.mode == nil or conn:mode() ~= nil) and
                   is_candidate_match_dynamic(local_instance, opts) then
                    return conn
                end


                break
            end
        end
    end

    local candidate = acquire_any_instance(instances, opts)

    if candidate ~= nil then
        return candidate
    end

    return nil, "no candidates are available with these conditions"
end

-- This method looks for an active connection in the specified
-- set of instances taking the priorities into account.
--
-- If there is no such connection the method connects to all
-- of the instances and selects the one with the highest priority.
local function select_connection_from_list_prioritized(instances, opts)
    assert(opts ~= nil and type(opts) == 'table')
    assert(opts.mode == 'prefer_ro' or opts.mode == 'prefer_rw')

    -- In case there are specified prioritizing of matching
    -- instances we fetch all matched static candidates.
    -- Technically, it's possible to speedup fetching the instances
    -- if there is already a connection to a top-priority connection
    -- (e.g. one RO instance is established and the mode is
    -- 'prefer_ro')
    local candidates = acquire_all_instances(instances)
    if next(candidates) == nil then
        return nil, "no candidates are available with these conditions"
    end

    -- Initialize the weight of each candidate.
    local weights = {}
    for _, instance_name in pairs(candidates) do
        weights[instance_name] = 0
    end

    -- Increase weights of candidates preferred by mode.
    if opts.mode == 'prefer_rw' or opts.mode == 'prefer_ro' then
        local mode = opts.mode == 'prefer_ro' and 'ro' or 'rw'
        local weight_mode = 2
        for _, instance_name in pairs(candidates) do
            local conn = connections[instance_name]
            assert(conn ~= nil)
            if conn:mode() == mode then
                weights[instance_name] = weights[instance_name] + weight_mode
            end
        end
    end

    -- Increase weight of local candidate.
    if opts.prefer_local ~= false then
        local local_instance_name = box.info.name

        local weight_local = 1
        if weights[local_instance_name] ~= nil then
            weights[local_instance_name] = weights[local_instance_name] +
                                           weight_local
        end
    end

    -- Select candidate by weight.
    while next(weights) ~= nil do
        local max_weight = 0
        for _, weight in pairs(weights) do
            if weight > max_weight then
                max_weight = weight
            end
        end
        local preferred_candidates = {}
        for instance_name, weight in pairs(weights) do
            if weight == max_weight then
                table.insert(preferred_candidates, instance_name)
            end
        end
        while #preferred_candidates > 0 do
            local n = math.random(#preferred_candidates)
            local instance_name = table.remove(preferred_candidates, n)
            local conn = connect(instance_name, {wait_connected = false})
            if conn:wait_connected() then
                return conn
            end
        end
        for _, instance_name in pairs(preferred_candidates) do
            weights[instance_name] = nil
        end
    end
    return nil, "connection to candidates failed"
end

-- This method looks for an active connection in the whole
-- connection pool taking the specified priorities in account.
--
-- If there is no such connection the method tries to
-- establish it with one of the matching replicas.
--
-- Used as a subroutine for the `call()` method.
local function select_connection(opts)
    assert(opts.mode == nil or opts.mode == 'ro' or opts.mode == 'rw' or
           opts.mode == 'prefer_ro' or opts.mode == 'prefer_rw')

    -- It's better to use the local instance to perform the call
    -- faster. So prefer the local instance by default.
    local prefer_local = true
    if opts.prefer_local ~= nil then
        prefer_local = opts.prefer_local
    end

    local filter_static_opts = {
        groups = opts.groups,
        replicasets = opts.replicasets,
        instances = opts.instances,
        labels = opts.labels,
        roles = opts.roles,
        sharding_roles = opts.sharding_roles,

        -- The connection check isn't needed since it connects
        -- to all of the candidates while we're trying to acquire
        -- any candidate.
        skip_connection_check = true,
    }

    -- At first we want to acquire the instances matching the
    -- static (configuration) requirements.
    local static_candidates = filter(filter_static_opts)

    -- In case we don't need to prioritize the matching instances
    -- we can wait for any connection available.
    local need_priorities =
        opts.mode == 'prefer_rw' or opts.mode == 'prefer_ro'

    local dynamic_opts = {
        mode = opts.mode,
        prefer_local = prefer_local,
    }

    if need_priorities then
        return select_connection_from_list_prioritized(static_candidates,
                                                       dynamic_opts)
    else
        return select_connection_from_list(static_candidates, dynamic_opts)
    end
end

local function call(func_name, args, opts)
    checks('string', '?table', {
        groups = '?table',
        replicasets = '?table',
        instances = '?table',
        labels = '?table',
        roles = '?table',
        sharding_roles = '?table',
        prefer_local = '?boolean',
        mode = '?string',
        -- The following options passed directly to net.box.call().
        timeout = '?',
        buffer = '?',
        on_push = '?function',
        on_push_ctx = '?',
        is_async = '?boolean',
    })
    opts = opts or {}
    if opts.mode ~= nil and opts.mode ~= 'ro' and opts.mode ~= 'rw' and
       opts.mode ~= 'prefer_ro' and opts.mode ~= 'prefer_rw' then
        local msg = 'Expected nil, "ro", "rw", "prefer_ro" or "prefer_rw", ' ..
                    'got "%s"'
        error(msg:format(opts.mode), 0)
    end

    local conn_opts = {
        groups = opts.groups,
        replicasets = opts.replicasets,
        instances = opts.instances,
        labels = opts.labels,
        roles = opts.roles,
        sharding_roles = opts.sharding_roles,
        prefer_local = opts.prefer_local,
        mode = opts.mode,
    }
    local conn, err = select_connection(conn_opts)
    if conn == nil then
        local msg = "Couldn't execute function %s: %s"
        error(msg:format(func_name, err), 0)
    end

    local net_box_call_opts = {
        timeout = opts.timeout,
        buffer = opts.buffer,
        on_push = opts.on_push,
        on_push_ctx = opts.on_push_ctx,
        is_async = opts.is_async,
    }
    return conn:call(func_name, args, net_box_call_opts)
end

return {
    connect = connect,
    filter = filter,
    call = call,
}
