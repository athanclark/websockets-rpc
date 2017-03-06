{-# LANGUAGE
    TemplateHaskell
  , NamedFieldPuns
  , ScopedTypeVariables
  #-}

module Main where

import Network.WebSockets (runServer, runClient, ServerApp, ClientApp)
import Network.WebSockets.RPC
import Data.Aeson.TH (deriveJSON, defaultOptions)
import Network.Wai.Trans (ClientAppT, runClientAppT, ServerAppT, runServerAppT)
import Control.Concurrent (threadDelay, forkIO)
import Control.Monad (forM_, when, void)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Catch (MonadThrow)
import Control.Monad.Random.Class (getRandom)


-- subscriptions from client to server
data MySubDSL = Foo
  deriving (Show, Eq)

$(deriveJSON defaultOptions ''MySubDSL)

-- supplies from client to server
data MySupDSL = Bar
  deriving (Show, Eq)

$(deriveJSON defaultOptions ''MySupDSL)

-- replies from server to client
data MyRepDSL = Baz
  deriving (Show, Eq)

$(deriveJSON defaultOptions ''MyRepDSL)

-- onCompletes from server to client
data MyComDSL = Qux
  deriving (Show, Eq)

$(deriveJSON defaultOptions ''MyComDSL)




myServer :: (MonadIO m, MonadThrow m) => ServerAppT (WebSocketServerRPCT MySubDSL MySupDSL m)
myServer = rpcServer $ \RPCServerParams{reply,complete} eSubSup -> case eSubSup of
  Left Foo -> do
    liftIO $ print Foo
    forM_ [1..5] $ \_ -> do
      liftIO $ threadDelay 1000000
      reply Baz
    complete Qux
  Right Bar -> do
    liftIO $ print Bar
    reply Baz



myClient :: (MonadIO m, MonadThrow m) => ClientAppT (WebSocketClientRPCT MyRepDSL MyComDSL m) ()
myClient = rpcClient $ \dispatch ->
  -- only going to make one RPC call for this example
  dispatch RPCClient
    { subscription = Foo
    , onReply = \RPCClientParams{supply,cancel} Baz -> do
        liftIO $ print Baz
        liftIO $ threadDelay 1000000
        supply Bar
        (q :: Bool) <- liftIO getRandom
        when q $ do
          liftIO $ putStrLn "Canceling..."
          cancel
    , onComplete = \Qux ->
        liftIO $ print Qux
    }





main :: IO ()
main = do
  let myServer' :: ServerApp
      myServer' = runServerAppT execWebSocketServerRPCT myServer

      myClient' :: ClientApp ()
      myClient' = runClientAppT execWebSocketClientRPCT myClient

  void $ forkIO $ runServer "127.0.0.1" 8080 myServer'
  threadDelay 1000000
  runClient "127.0.0.1" 8080 "" myClient'
