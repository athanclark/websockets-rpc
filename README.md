websockets-rpc
===============

A simple message-based streaming RPC mechanism built using WebSockets

## Usage

The idea is pretty simple:

- A client initiates the RPC call to a server with a `Subscription`
- the client may send additional data at any time with `Supply`, who can also cancel the RPC call
- the server may respond incrementally with `Reply`
- the server finishes the RPC call with a `Complete`

```
client                                                         server
    ------------------------subscribe--------------------------->
    - - - - - - - - - - - - -supply - - - - - - - - - - - - - - >
    < - - - - - - - - - - - -reply- - - - - - - - - - - - - - - -
    <-----------------------complete-----------------------------
```

if the `supply` and `reply` parts were ommitted, it would be identical to a traditional RPC mechanism.


### Example

```haskell
import Network.WebSockets.RPC
import Data.Aeson

-- subscriptions from client to server
data MySubDSL = Foo
  deriving (FromJSON, ToJSON) -- you should figure this part out :)

-- supplies from client to server
data MySupDSL = Bar
  deriving (FromJSON, ToJSON)

-- replies from server to client
data MyRepDSL = Baz
  deriving (FromJSON, ToJSON)

-- onCompletes from server to client
data MyComDSL = Qux
  deriving (FromJSON, ToJSON)
```


Server:

```haskell
{-# LANGUAGE NamedFieldPuns, ScopedTypeVariables #-}


myServer :: (MonadIO m, MonadThrow m) => ServerAppT (WebSocketServerRPCT MySubDSL MySupDSL m)
myServer = rpcServer $ \RPCServerParams{reply,complete} eSubSup -> case eSubSup of
  Left Foo -> do
    forM_ [1..5] $ \_ -> do
      liftIO $ threadDelay 1000000
      reply Baz
    complete Qux
  Right Bar -> reply Baz
```

Client:

```haskell
{-# LANGUAGE NamedFieldPuns #-}


myClient :: (MonadIO m, MonadThrow m) => ClientAppT (WebSocketClientRPCT MyRepDSL MyComDSL m) ()
myClient = rpcClient $ \dispatch ->
  -- only going to make one RPC call for this example
  dispatch RPCClient
    { subscription = Foo
    , onReply = \RPCClientParams{supply,cancel} Baz -> do
        liftIO $ threadDelay 1000000
        supply Bar
        (q :: Bool) <- liftIO getRandom
        if q then cancel else pure ()
    , onComplete = \Qux -> liftIO $ putStrLn "finished"
    }
```

> the `threadDelay` calls are just to exemplify the asynchronisity of the system, nothing to do with avoiding race conditions >.>


To turn the `ServerAppT` and `ClientAppT` into natural [WebSockets](https://hackage.haskell.org/package/websockets)
types, use the morphisms from [Wai-Transformers](https://hackage.haskell.org/package/wai-trasformers).


## Contributing

this is my swamp
