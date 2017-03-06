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




myServer :: (MonadIO m, MonadThrow m) => ServerAppT (WebSocketServerRPCT MySubDSL MySupDSL m)
myServer = rpcServer $ \RPCServerParams{reply,complete} eSubSup -> case eSubSup of
  Left Foo -> do
    liftIO $ print Foo
    forM_ [1..5] $ \_ -> do
      liftIO $ threadDelay 1000000
      liftIO $ putStrLn "Replying Baz..."
      reply Baz
    liftIO $ putStrLn "Completing Qux..."
    complete Qux
  Right Bar -> do
    liftIO $ print Bar
    liftIO $ putStrLn "Replying Baz..."
    reply Baz




main :: IO ()
main = do
  let myServer' :: ServerApp
      myServer' = runServerAppT execWebSocketServerRPCT myServer

  runServer "127.0.0.1" 8080 myServer'
