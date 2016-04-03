defmodule Cachex do
  # use Macros and Supervisor
  use Cachex.Macros.Boilerplate
  use Supervisor

  # add some aliases
  alias Cachex.Util

  @moduledoc """
  Cachex provides a straightforward interface for in-memory key/value storage.

  Cachex is an extremely fast, designed for caching but also allowing for more
  general in-memory storage. The main goal of Cachex is achieve a caching implementation
  with a wide array of options, without sacrificing performance. Internally, Cachex
  is backed by ETS and Mnesia, allowing for an easy-to-use interface sitting upon
  extremely well tested tools.

  Cachex comes with support for all of the following (amongst other things):

  - Time-based key expirations
  - Pre/post execution hooks
  - Statistics gathering
  - Multi-layered caching/key fallbacks
  - Distribution to remote nodes
  - Transactions and row locking
  - Asynchronous write operations

  All features are optional to allow you to tune based on the throughput needed.
  See `start_link/2` for further details about how to configure these options and
  example usage.
  """

  # the default timeout for a GenServer call
  @def_timeout 250

  # custom options type
  @type options :: [ { atom, any } ]

  # custom status type
  @type status :: :ok | :error | :missing

  @doc """
  Initialize the Mnesia table and supervision tree for this cache.

  We also allow the user to define their own options for the cache. We start a
  Supervisor to look after all internal workers backing the cache, in order to
  make sure everything is fault-tolerant.

  ## Options

  ### Required

    - **name**

      The name of the cache you're creating, typically an atom.

          Cachex.start_link([ name: :my_cache ])

  ### Optional

    - **ets_opts**

      A list of options to pass to the ETS table initialization.

          Cachex.start_link([ name: :my_cache, ets_opts: [ { :write_concurrency, false } ] ])

    - **default_fallback**

      A default fallback implementation to use when dealing with multi-layered caches.
      This function is called with a key which has no value, in order to allow loading
      from a different location.

          Cachex.start_link([ name: :my_cache, default_fallback: fn(key) ->
            generate_value(key)
          end])

    - **default_ttl**

      A default expiration time to place on any keys inside the cache (this can be
      overridden when a key is set). This value is in **milliseconds**.

          Cachex.start_link([ name: :my_cache, default_ttl: :timer.seconds(1) ])

    - **fallback_args**

      A list of arguments which can be passed to your fallback functions for multi-layered
      caches. The fallback function receives `[key] ++ args`, so make sure you configure
      your args appropriately. This can be used to pass through things such as clients and
      connections.

          Cachex.start_link([ name: :my_cache, fallback_args: [redis_client] ])
          Cachex.get(:my_cache, "key", fallback: fn(key, redis_client) ->
            redis_client.get(key)
          end)

    - **hooks**

      A list of hooks which will be executed either before or after a Cachex action has
      taken place. These hooks should be instances of Cachex.Hook and implement the hook
      behaviour. An example hook can be found in `Cachex.Stats`.

        hook = %Cachex.Hook{ module: MyHook, type: :post }
        Cachex.start_link([ name: :my_cache, hooks: [hook] ])

    - **nodes**

      A list of nodes that the store should replicate to. Using this does not automatically
      enable transactions; they need to be enabled separately.

          Cachex.start_link([ name: :my_cache, nodes: [node()] ])

    - **record_stats**

      Whether you wish this cache to record usage statistics or not. This has only minor
      overhead due to being implemented as an asynchronous hook (roughly 1µ/op). Stats
      can be retrieve from a running cache by using `stats/1`.

          Cachex.start_link([ name: :my_cache, record_stats: true ])

    - **remote**

      Whether to use `remote` behaviours or not. This means that all writes go through
      Mnesia rather than straight to ETS (and as such there is a slowdown). This is
      automatically set to true if you have set `:nodes` to a list of nodes other than
      just `[node()]`.

          Cachex.start_link([ name: :my_cache, remote: true ])

    - **transactional**

      Whether to implement actions using a transactional interface. Transactions ensure
      row locks on all operations and are naturally a lot slower than when not in use.
      This implementation is likely not needed unless it's mission-critical to distribute
      and you have a lot of writes going to the same keys. Note that this is at least 10x
      slower than when set to false.

          Cachex.start_link([ name: :my_cache, transactional: true ])

    - **ttl_interval**

      Keys are purged on a schedule (defaults to once a second). This value can be changed
      to customize the schedule that keys are purged on. Be aware that if a key is accessed
      when it *should* have expired, but has not yet been purged, it will be removed at that
      time. The purge runs in a separate process so it doesn't have a negative effect on the
      application, but it may make sense to lower the frequency if you don't have many keys
      expiring at one time. This value is set in **milliseconds**.

          Cachex.start_link([ name: :my_cache, ttl_interval: :timer.seconds(5) ])

  """
  @spec start_link(options, options) :: { atom, pid }
  def start_link(options \\ [], supervisor_options \\ []) do
    case options[:name] do
      name when not is_atom(name) or name == nil ->
        { :error, "Cache name must be a valid atom" }
      name ->
        case Process.whereis(name) do
          nil ->
            Supervisor.start_link(__MODULE__, options, supervisor_options)
          pid ->
            { :error, "Cache name already in use for #{inspect(pid)}" }
        end
    end
  end

  @doc """
  Basic initialization phase, being passed arguments by the Supervisor.

  This function sets up the Mnesia table and options are parsed before being used
  to setup the internal workers. Workers are then given to `supervise/2`.
  """
  @spec init(options) :: { status, { any } }
  def init(options \\ []) when is_list(options) do
    parsed_opts =
      options
      |> Cachex.Options.parse

    table_create = :mnesia.create_table(parsed_opts.cache, [
      { :ram_copies, parsed_opts.nodes },
      { :attributes, [ :key, :touched, :ttl, :value ]},
      { :type, :set },
      { :storage_properties, [ { :ets, parsed_opts.ets_opts } ] }
    ])

    with { :atomic, :ok } <- table_create do
      ttl_workers = case parsed_opts.ttl_interval do
        nil -> []
        _other -> [worker(Cachex.Janitor, [parsed_opts])]
      end

      children = ttl_workers ++ [
        worker(Cachex.Worker, [parsed_opts, [name: parsed_opts.cache]])
      ]

      supervise(children, strategy: :one_for_one)
    end
  end

  @doc """
  Retrieves a value from the cache using a given key.

  ## Options

    * `:fallback` - a fallback function for multi-layered caches, overriding any
      default fallback functions. The value returned by this fallback is placed
      in the cache against the provided key, before being returned to the user.

  ## Examples

      iex> Cachex.set(:my_cache, "key", "value")
      iex> Cachex.get(:my_cache, "key")
      { :ok, "value" }

      iex> Cachex.get(:my_cache, "missing_key")
      { :missing, nil }

      iex> Cachex.get(:my_cache, "missing_key", fallback: &(String.reverse/1))
      { :loaded, "yek_gnissim" }

  """
  @spec get(atom, any, options) :: { status | :loaded, any }
  defcheck get(cache, key, options \\ []) when is_list(options) do
    GenServer.call(cache, { :get, key, options }, @def_timeout)
  end

  @doc """
  Updates a value in the cache, feeding any existing values into an update function.

  This operation is an internal mutation, and as such any set TTL persists - i.e.
  it is not refreshed on this operation.

  ## Options

    * `:fallback` - a fallback function for multi-layered caches, overriding any
      default fallback functions. The value returned by this fallback is passed
      into the update function.

  ## Examples

      iex> Cachex.set(:my_cache, "key", [2])
      iex> Cachex.get_and_update(:my_cache, "key", &([1|&1]))
      { :ok, [1, 2] }

      iex> Cachex.get_and_update(:my_cache, "missing_key", &(["value"|&1]), fallback: &(String.reverse/1))
      { :loaded, [ "value", "yek_gnissim" ] }

  """
  @spec get_and_update(atom, any, function, options) :: { status | :loaded, any }
  defcheck get_and_update(cache, key, update_function, options \\ [])
  when is_function(update_function) and is_list(options) do
    GenServer.call(cache, { :get_and_update, key, update_function, options }, @def_timeout)
  end

  @doc """
  Sets a value in the cache against a given key.

  This will overwrite any value that was previously set against the provided key,
  and overwrite any TTLs which were already set.

  ## Options

    * `:async` - whether to wait on a response from the server, or to execute in
      the background.
    * `:ttl` - a time-to-live for the provided key/value pair, overriding any
      default ttl. This value should be in milliseconds.

  ## Examples

      iex> Cachex.set(:my_cache, "key", "value")
      { :ok, true }

      iex> Cachex.set(:my_cache, "key", "value", async: true)
      { :ok, true }

      iex> Cachex.set(:my_cache, "key", "value", ttl: :timer.seconds(5))
      { :ok, true }

  """
  @spec set(atom, any, any, options) :: { status, true | false }
  defcheck set(cache, key, value, options \\ []) when is_list(options) do
    handle_async(cache, { :set, key, value, options }, options)
  end

  @doc """
  Updates a value in the cache. Unlike `get_and_update/4`, this does a blind
  overwrite.

  This operation is an internal mutation, and as such any set TTL persists - i.e.
  it is not refreshed on this operation.

  ## Options

    * `:async` - whether to wait on a response from the server, or to execute in
      the background.

  ## Examples

      iex> Cachex.set(:my_cache, "key", "value")
      iex> Cachex.get(:my_cache, "key")
      { :ok, "value" }

      iex> Cachex.update(:my_cache, "key", "new_value")
      iex> Cachex.get(:my_cache, "key")
      { :ok, "new_value" }

      iex> Cachex.update(:my_cache, "key", "final_value", async: true)
      iex> Cachex.get(:my_cache, "key")
      { :ok, "final_value" }

      iex> Cachex.update(:my_cache, "missing_key", "new_value")
      { :missing, false }

  """
  @spec update(atom, any, any, options) :: { status, any }
  defcheck update(cache, key, value, options \\ []) when is_list(options) do
    handle_async(cache, { :update, key, value, options }, options)
  end

  @doc """
  Removes a value from the cache.

  This will return `{ :ok, true }` regardless of whether a key has been removed
  or not. The `true` value can be thought of as "is value is no longer present?".

  ## Options

    * `:async` - whether to wait on a response from the server, or to execute in
      the background.

  ## Examples

      iex> Cachex.del(:my_cache, "key")
      { :ok, true }

      iex> Cachex.del(:my_cache, "key", async: true)
      { :ok, true }

  """
  @spec del(atom, any, options) :: { status, true | false }
  defcheck del(cache, key, options \\ []) when is_list(options) do
    handle_async(cache, { :del, key, options }, options)
  end

  @doc """
  Removes all key/value pairs from the cache.

  This function returns a tuple containing the total number of keys removed from
  the internal cache. This is equivalent to running `size/2` before running `clear/2`.

  ## Options

    * `:async` - whether to wait on a response from the server, or to execute in
      the background.

  ## Examples

      iex> Cachex.set(:my_cache, "key1", "value1")
      iex> Cachex.clear(:my_cache)
      { :ok, 1 }

      iex> Cachex.set(:my_cache, "key1", "value1")
      iex> Cachex.clear(:my_cache, async: true)
      { :ok, true }

  """
  @spec clear(atom, options) :: { status, true | false }
  defcheck clear(cache, options \\ []) when is_list(options) do
    handle_async(cache, { :clear, options }, options)
  end

  @doc """
  Determines the current size of the unexpired keyspace.

  Unlike `size/2`, this ignores keys which should have expired. Due to this taking
  potentially expired keys into account, it is far more expensive than simply
  calling `size/2` and should only be used when completely necessary.

  ## Examples

      iex> Cachex.set(:my_cache, "key1", "value1")
      iex> Cachex.set(:my_cache, "key2", "value2")
      iex> Cachex.set(:my_cache, "key3", "value3")
      iex> Cachex.count(:my_cache)
      { :ok, 3 }

  """
  @spec count(atom, options) :: { status, number }
  defcheck count(cache, options \\ []) when is_list(options) do
    GenServer.call(cache, { :count, options }, @def_timeout)
  end

  @doc """
  Decrements a key directly in the cache.

  This operation is an internal mutation, and as such any set TTL persists - i.e.
  it is not refreshed on this operation.

  ## Options

    * `:async` - whether to wait on a response from the server, or to execute in
      the background.
    * `:amount` - an amount to decrement by. This will default to 1.
    * `:initial` - if the key does not exist, it will be initialized to this amount.
      Defaults to 0.

  ## Examples

      iex> Cachex.set(:my_cache, "my_key", 10)
      iex> Cachex.decr(:my_cache, "my_key")
      { :ok, 9 }

      iex> Cachex.decr(:my_cache, "my_key", async: true)
      { :ok, true }

      iex> Cachex.set(:my_cache, "my_new_key", 10)
      iex> Cachex.decr(:my_cache, "my_new_key", amount: 5)
      { :ok, 5 }

      iex> Cachex.decr(:my_cache, "missing_key", amount: 5, initial: 0)
      { :ok, -5 }

  """
  @spec decr(atom, any, options) :: { status, number }
  defcheck decr(cache, key, options \\ []),
  do: incr(cache, key, Keyword.update(options, :amount, -1, &(&1 * -1)))

  @doc """
  Checks whether the cache is empty.

  This operates based on keys living in the cache, regardless of whether they should
  have expired previously or not. Internally this is just sugar for checking if
  `size/2` returns 0.

  ## Examples

      iex> Cachex.set(:my_cache, "key1", "value1")
      iex> Cachex.empty?(:my_cache)
      { :ok, false }

      iex> Cachex.clear(:my_cache)
      { :ok, 1 }

      iex> Cachex.empty?(:my_cache)
      { :ok, true }

  """
  @spec empty?(atom, options) :: { status, true | false }
  defcheck empty?(cache, options \\ []) when is_list(options) do
    case size(cache) do
      { :ok, 0 } -> { :ok, true }
      _other_value_ -> { :ok, false }
    end
  end

  @doc """
  Determines whether a given key exists inside the cache.

  This only determines if the key lives in the keyspace of the cache. Note that
  this determines existence within the bounds of TTLs; this means that if a key
  doesn't "exist", it may still be occupying memory in the cache.

  ## Examples

      iex> Cachex.set(:my_cache, "key", "value")
      iex> Cachex.exists?(:my_cache, "key")
      { :ok, true }

      iex> Cachex.exists?(:my_cache, "missing_key")
      { :ok, false }

  """
  @spec exists?(atom, any, options) :: { status, true | false }
  defcheck exists?(cache, key, options \\ []) when is_list(options) do
    GenServer.call(cache, { :exists?, key, options }, @def_timeout)
  end

  @doc """
  Sets a TTL on a key in the cache in milliseconds.

  If the key does not exist in the cache, you will receive a result indicating
  this.

  ## Options

    * `:async` - whether to wait on a response from the server, or to execute in
      the background.

  ## Examples

      iex> Cachex.set(:my_cache, "key", "value")
      iex> Cachex.expire(:my_cache, "key", :timer.seconds(5))
      { :ok, true }

      iex> Cachex.expire(:my_cache, "missing_key", :timer.seconds(5))
      { :missing, false }

      iex> Cachex.expire(:my_cache, "key", :timer.seconds(5), async: true)
      { :ok, true }

      iex> Cachex.expire(:my_cache, "missing_key", :timer.seconds(5), async: true)
      { :ok, true }

  """
  @spec expire(atom, any, number, options) :: { status, true | false }
  defcheck expire(cache, key, expiration, options \\ [])
  when is_number(expiration) and is_list(options) do
    handle_async(cache, { :expire, key, expiration, options }, options)
  end

  @doc """
  Updates the expiration time on a given cache entry to expire at the time provided.

  If the key does not exist in the cache, you will receive a result indicating
  this. If the expiration date is in the past, the key will be immediately evicted
  when this function is called.

  ## Options

    * `:async` - whether to wait on a response from the server, or to execute in
      the background.

  ## Examples

      iex> Cachex.set(:my_cache, "key", "value")
      iex> Cachex.expire_at(:my_cache, "key", 1455728085502)
      { :ok, true }

      iex> Cachex.expire_at(:my_cache, "missing_key", 1455728085502)
      { :missing, false }

      iex> Cachex.expire_at(:my_cache, "key", 1455728085502, async: true)
      { :ok, true }

      iex> Cachex.expire_at(:my_cache, "missing_key", 1455728085502, async: true)
      { :ok, true }

  """
  @spec expire_at(atom, binary, number, options) :: { status, true | false }
  defcheck expire_at(cache, key, timestamp, options \\ [])
  when is_number(timestamp) and is_list(options) do
    handle_async(cache, { :expire_at, key, timestamp, options }, options)
  end

  @doc """
  Retrieves all keys from the cache, and returns them as an (unordered) list.

  ## Examples

      iex> Cachex.set(:my_cache, "key1", "value1")
      iex> Cachex.set(:my_cache, "key2", "value2")
      iex> Cachex.set(:my_cache, "key3", "value3")
      iex> Cachex.keys(:my_cache)
      { :ok, [ "key2", "key1", "key3" ] }

      iex> Cachex.clear(:my_cache)
      iex> Cachex.keys(:my_cache)
      { :ok, [] }

  """
  @spec keys(atom, options) :: [ any ]
  defcheck keys(cache, options \\ []) when is_list(options) do
    GenServer.call(cache, { :keys, options }, @def_timeout)
  end

  @doc """
  Increments a key directly in the cache.

  This operation is an internal mutation, and as such any set TTL persists - i.e.
  it is not refreshed on this operation.

  ## Options

    * `:async` - whether to wait on a response from the server, or to execute in
      the background.
    * `:amount` - an amount to increment by. This will default to 1.
    * `:initial` - if the key does not exist, it will be initialized to this amount
      before being modified. Defaults to 0.

  ## Examples

      iex> Cachex.set(:my_cache, "my_key", 10)
      iex> Cachex.incr(:my_cache, "my_key")
      { :ok, 11 }

      iex> Cachex.incr(:my_cache, "my_key", async: true)
      { :ok, true }

      iex> Cachex.set(:my_cache, "my_new_key", 10)
      iex> Cachex.incr(:my_cache, "my_new_key", amount: 5)
      { :ok, 15 }

      iex> Cachex.incr(:my_cache, "missing_key", amount: 5, initial: 0)
      { :ok, 5 }

  """
  @spec incr(atom, any, options) :: { status, number }
  defcheck incr(cache, key, options \\ []) when is_list(options) do
    handle_async(cache, { :incr, key, options }, options)
  end

  @doc """
  Removes a TTL on a given document.

  ## Options

    * `:async` - whether to wait on a response from the server, or to execute in
      the background.

  ## Examples

      iex> Cachex.set(:my_cache, "key", "value", ttl: 1000)
      iex> Cachex.persist(:my_cache, "key")
      { :ok, true }

      iex> Cachex.persist(:my_cache, "missing_key")
      { :missing, false }

      iex> Cachex.persist(:my_cache, "missing_key", async: true)
      { :ok, true }

  """
  @spec persist(atom, any, options) :: { status, true | false }
  defcheck persist(cache, key, options \\ []) when is_list(options) do
    handle_async(cache, { :persist, key, options }, options)
  end

  @doc """
  Triggers a mass deletion of all expired keys.

  This can be used to implement custom eviction policies rather than relying on
  the internal policy. Be careful though, calling `purge/2` manually will result
  in the purge firing inside the main process rather than inside the TTL worker.

  ## Options

    * `:async` - whether to wait on a response from the server, or to execute in
      the background.

  ## Examples

      iex> Cachex.purge(:my_cache)
      { :ok, 15 }

      iex> Cachex.purge(:my_cache, async: true)
      { :ok, true }

  """
  @spec purge(atom, options) :: { status, number }
  defcheck purge(cache, options \\ []) when is_list(options) do
    handle_async(cache, { :purge, options }, options)
  end


  @doc """
  Refreshes the TTL for the provided key. This will reset the TTL to begin from
  the current time.

  ## Options

    * `:async` - whether to wait on a response from the server, or to execute in
      the background.

  ## Examples

      iex> Cachex.set(:my_cache, "my_key", "my_value", ttl: :timer.seconds(5))
      iex> :timer.sleep(4)
      iex> Cachex.refresh(:my_cache, "my_key")
      iex> Cachex.ttl(:my_cache, "my_key")
      { :ok, 5000 }

      iex> Cachex.refresh(:my_cache, "missing_key")
      { :missing, false }

      iex> Cachex.refresh(:my_cache, "my_key", async: true)
      { :ok, true }

      iex> Cachex.refresh(:my_cache, "missing_key", async: true)
      { :ok, true }

  """
  @spec refresh(atom, any, options) :: { status, true | false }
  defcheck refresh(cache, key, options \\ []) when is_list(options) do
    handle_async(cache, { :refresh, key, options }, options)
  end

  @doc """
  Determines the total size of the cache.

  This includes any expired but unevicted keys. For a more representation which
  doesn't include expired keys, use `count/2`.

  ## Examples

      iex> Cachex.set(:my_cache, "key1", "value1")
      iex> Cachex.set(:my_cache, "key2", "value2")
      iex> Cachex.set(:my_cache, "key3", "value3")
      iex> Cachex.size(:my_cache)
      { :ok, 3 }

  """
  @spec size(atom, options) :: { status, number }
  defcheck size(cache, options \\ []) when is_list(options) do
    GenServer.call(cache, { :size, options }, @def_timeout)
  end

  @doc """
  Retrieves the statistics of a cache.

  If statistics gathering is not enabled, an error is returned.

  ## Examples

      iex> Cachex.stats(:my_cache)
      {:ok,
       %{creationDate: 1455690638577, evictionCount: 0, expiredCount: 0, hitCount: 0,
         missCount: 0, opCount: 0, requestCount: 0, setCount: 0}}

      iex> Cachex.stats(:cache_with_no_stats)
      { :error, "Stats not enabled for cache with ref ':cache_with_no_stats'" }

  """
  @spec stats(atom, options) :: { status, %{ } }
  defcheck stats(cache, options \\ []) when is_list(options) do
    GenServer.call(cache, { :stats, options }, @def_timeout)
  end

  @doc """
  Takes a key from the cache.

  This is equivalent to running `get/3` followed by `del/3` in a single action.

  ## Examples

      iex> Cachex.set(:my_cache, "key", "value")
      iex> Cachex.take(:my_cache, "key")
      { :ok, "value" }

      iex> Cachex.get(:my_cache, "key")
      { :missing, nil }

      iex> Cachex.take(:my_cache, "missing_key")
      { :missing, nil }

  """
  @spec take(atom, any, options) :: { status, any }
  defcheck take(cache, key, options \\ []) when is_list(options) do
    GenServer.call(cache, { :take, key, options }, @def_timeout)
  end

  @doc """
  Returns the TTL for a cache entry in milliseconds.

  ## Examples

      iex> Cachex.ttl(:my_cache, "my_key")
      { :ok, 13985 }

      iex> Cachex.ttl(:my_cache, "missing_key")
      { :missing, nil }

  """
  @spec ttl(atom, any, options) :: { status, number }
  defcheck ttl(cache, key, options \\ []) when is_list(options) do
    GenServer.call(cache, { :ttl, key, options }, @def_timeout)
  end

  # Internal function to handle async delegation. This is just a wrapper around
  # the call/cast functions inside the GenServer module.
  defp handle_async(cache, args, options) do
    if options[:async] do
      cache
      |> GenServer.cast(args)
      |> (&(Util.create_truthy_result/1)).()
    else
      GenServer.call(cache, args, @def_timeout)
    end
  end

end