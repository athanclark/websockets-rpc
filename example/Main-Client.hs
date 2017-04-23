{-# LANGUAGE
    TemplateHaskell
  , NamedFieldPuns
  , ScopedTypeVariables
  #-}

module Main where

import Network.WebSockets (runServer, runClient, ServerApp, ClientApp)
import Network.WebSockets.RPC
import Data.Aeson.TH (deriveJSON, defaultOptions, sumEncoding, SumEncoding (TwoElemArray))
import Network.Wai.Trans (ClientAppT, runClientAppT, ServerAppT, runServerAppT)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, link)
import Control.Monad (forM_, when, void)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Catch (MonadThrow)
import Control.Monad.Random.Class (getRandom)


-- subscriptions from client to server
data MySubDSL = Foo
  deriving (Show, Eq)

$(deriveJSON defaultOptions{sumEncoding = TwoElemArray} ''MySubDSL)

-- supplies from client to server
data MySupDSL = Bar
  deriving (Show, Eq)

$(deriveJSON defaultOptions{sumEncoding = TwoElemArray} ''MySupDSL)

-- replies from server to client
data MyRepDSL = Baz
  deriving (Show, Eq)

$(deriveJSON defaultOptions{sumEncoding = TwoElemArray} ''MyRepDSL)

-- onCompletes from server to client
data MyComDSL = Qux
  deriving (Show, Eq)

$(deriveJSON defaultOptions{sumEncoding = TwoElemArray} ''MyComDSL)




myClient :: (MonadIO m, MonadThrow m) => ClientAppT (WebSocketClientRPCT MyRepDSL MyComDSL m) ()
myClient = rpcClient $ \dispatch -> do
  -- only going to make one RPC call for this example
  liftIO $ putStrLn "Subscribing Foo..."
  dispatch RPCClient
    { subscription = Foo
    , onSubscribe = \RPCClientParams{supply,cancel} -> do
        liftIO $ putStrLn "Supplying Bar..."
        supply Bar
    , onReply = \RPCClientParams{supply,cancel} Baz -> do
        liftIO $ print Baz
        liftIO $ threadDelay 1000000
        liftIO $ putStrLn "Supplying Bar..."
        supply Bar
        (q :: Int) <- (`mod` 10) <$> liftIO getRandom
        when (q == 0) $ do
          liftIO $ putStrLn "Canceling..."
          cancel
    , onComplete = \Qux ->
        liftIO $ print Qux
    }





main :: IO ()
main = do
  let myClient' :: ClientApp ()
      myClient' = runClientAppT execWebSocketClientRPCT myClient

  threadDelay 1000000
  runClient "127.0.0.1" 8080 "" myClient'
