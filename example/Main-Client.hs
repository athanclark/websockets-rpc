{-# LANGUAGE
    TemplateHaskell
  , NamedFieldPuns
  , ScopedTypeVariables
  #-}

module Main where

import Network.WebSockets (runServer, runClient, ServerApp, ClientApp)
import Network.WebSockets.RPC
import Network.WebSockets.RPC.ACKable (ackableRPCClient)
import Data.Aeson.TH (deriveJSON, defaultOptions, sumEncoding, SumEncoding (TwoElemArray))
import Network.Wai.Trans (ClientAppT, runClientAppT, ServerAppT, runServerAppT)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, link)
import Control.Monad (forM_, when, void)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Catch (MonadThrow, MonadCatch)
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




myClient :: (MonadIO m, MonadThrow m, MonadCatch m) => RPCClient MySubDSL MySupDSL MyRepDSL MyComDSL m
myClient = RPCClient
  { subscription = Foo
  , onSubscribe = \RPCClientParams{supply,cancel} -> do
      liftIO $ putStrLn "Supplying Bar..."
      supply Bar
  , onReply = \RPCClientParams{supply,cancel} Baz -> do
      liftIO $ print Baz
      liftIO $ threadDelay 1000000
      liftIO $ putStrLn "Supplying Bar..."
      supply Bar
  , onComplete = \Qux ->
      liftIO $ print Qux
  }





main :: IO ()
main = do
  client <- ackableRPCClient id ("client" :: String) myClient
  let myClient' :: ClientApp ()
      myClient' = runClientAppT execWebSocketClientRPCT $ rpcClient $ \dispatch -> do
        liftIO $ putStrLn "Subscribing Foo..."
        dispatch client

  threadDelay 1000000
  runClientAppTBackingOff id "127.0.0.1" 8080 "" myClient'
