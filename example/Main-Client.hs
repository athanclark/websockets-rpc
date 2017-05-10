{-# LANGUAGE
    TemplateHaskell
  , NamedFieldPuns
  , ScopedTypeVariables
  #-}

module Main where

import Network.Wai.Trans (runClientAppT)
import Network.WebSockets (runServer, runClient, ServerApp, ClientApp)
import Network.WebSockets.Simple (toClientAppT', hoistWebSocketsApp, expBackoffStrategy)
import Network.WebSockets.RPC
import Network.WebSockets.RPC.ACKable (ackableRPCClient)
import Network.WebSockets.RPC.Trans.Client (newEnv, Env, runWebSocketClientRPCT')
import Data.Aeson.TH (deriveJSON, defaultOptions, sumEncoding, SumEncoding (TwoElemArray))
import Network.Wai.Trans (ClientAppT, runClientAppT, ServerAppT, runServerAppT)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, link)
import Control.Monad (forM_, when, void)
import Control.Monad.Trans (lift)
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
  env <- newEnv

  let runM = id

      runWS :: WebSocketClientRPCT MyRepDSL MyComDSL IO a -> IO a
      runWS = runWebSocketClientRPCT' env

  client <- runWebSocketClientRPCT' env (rpcClientSimple (\_ -> putStrLn "connection closed"
                                                         ) myClient)

  -- client <- ackableRPCClient id ("client" :: String) myClient
  let myClient' :: ClientApp ()
      myClient' = runClientAppT runM $ toClientAppT' $ runWebSocketClientRPCTSimple runWS client

  threadDelay 1000000
  expBackoffStrategy $ runClient "127.0.0.1" 8080 "" $ runClientAppT id myClient'
