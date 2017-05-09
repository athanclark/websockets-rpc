{-# LANGUAGE
    RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  , FlexibleContexts
  #-}

module Network.WebSockets.RPC
  ( -- * Server
    RPCServerParams (..), RPCServer, rpcServer
  , -- * Client
    RPCClientParams (..), RPCClient (..), rpcClient
  , -- * Re-Exports
    WebSocketServerRPCT, execWebSocketServerRPCT, WebSocketClientRPCT, execWebSocketClientRPCT
  , WebSocketRPCException (..)
  , runClientAppTBackingOff
  , rpcServerSimple, rpcClientSimple
  , runWebSocketClientRPCTSimple
  , execWebSocketClientRPCTSimple
  , runWebSocketServerRPCTSimple
  , execWebSocketServerRPCTSimple
  ) where

import Network.WebSockets.RPC.Trans.Server ( WebSocketServerRPCT, execWebSocketServerRPCT
                                           , registerSubscribeSupply, runSubscribeSupply, unregisterSubscribeSupply
                                           , runWebSocketServerRPCT', getServerEnv)
import Network.WebSockets.RPC.Trans.Client ( WebSocketClientRPCT, execWebSocketClientRPCT
                                           , registerReplyComplete, runReply, runComplete, unregisterReplyComplete
                                           , freshRPCID, runWebSocketClientRPCT', getClientEnv
                                           )
import qualified Network.WebSockets.RPC.Trans.Server as Server
import qualified Network.WebSockets.RPC.Trans.Client as Client
import Network.WebSockets.RPC.Types ( WebSocketRPCException (..), Subscribe (..), Supply (..), Reply (..), Complete (..)
                                    , ClientToServer (Sub, Sup, Ping), ServerToClient (Rep, Com, Pong)
                                    , RPCIdentified (..)
                                    )
import Network.WebSockets (acceptRequest, receiveDataMessage, sendDataMessage, DataMessage (Text, Binary), ConnectionException, runClient)
import Network.WebSockets.Simple (WebSocketsApp (..), hoistWebSocketsApp)
import Network.Wai.Trans (ServerAppT, ClientAppT, runClientAppT)
import Data.Aeson (ToJSON, FromJSON, decode, encode)
import Data.IORef (newIORef, readIORef, writeIORef)

import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Catch (MonadThrow, throwM, MonadCatch, catch, SomeException)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Control (MonadBaseControl (..))
import Control.Concurrent (threadDelay)
import qualified Control.Concurrent.Async as Async


-- * Server

data RPCServerParams rep com m = RPCServerParams
  { reply    :: rep -> m () -- ^ dispatch a reply
  , complete :: com -> m () -- ^ dispatch a onComplete
  }

type RPCServer sub sup rep com m
  =  RPCServerParams rep com m
  -> Either sub sup -- ^ handle incoming message
  -> m ()

-- | May throw a 'WebSocketRPCParseFailure' if the opposing party sends bad data
rpcServer  :: forall sub sup rep com m
            . ( ToJSON rep
              , ToJSON com
              , FromJSON sub
              , FromJSON sup
              , MonadIO m
              , MonadThrow m
              , MonadBaseControl IO m
              )
            => RPCServer sub sup rep com m
            -> ServerAppT (WebSocketServerRPCT sub sup m)
rpcServer f pendingConn = do
  conn <- liftIO (acceptRequest pendingConn)
  void $ liftIO $ Async.async $ forever $ do
    sendDataMessage conn (Text (encode (Pong :: ServerToClient () ())) Nothing)
    threadDelay 1000000

  let runSub :: Subscribe sub -> WebSocketServerRPCT sub sup m ()
      runSub (Subscribe RPCIdentified{_ident,_params}) = do

        let reply :: rep -> m ()
            reply rep =
              let r = Reply RPCIdentified{_ident, _params = rep}
              in  liftIO (sendDataMessage conn (Text (encode r) Nothing))

            complete :: com -> m ()
            complete com =
              let c = Complete RPCIdentified{_ident, _params = com}
              in  liftIO (sendDataMessage conn (Text (encode c) Nothing))

            cont :: Either sub sup -> m ()
            cont eSubSup = liftBaseWith $ \runInBase -> void $ Async.async $
              void $ runInBase $ f RPCServerParams{reply,complete} eSubSup

        registerSubscribeSupply _ident cont
        runSubscribeSupply _ident (Left _params)

      runSup :: Supply sup -> WebSocketServerRPCT sub sup m ()
      runSup (Supply RPCIdentified{_ident,_params}) =
        case _params of
          Nothing     -> unregisterSubscribeSupply _ident -- FIXME this could bork the server if I `async` a routine thread
          Just params -> runSubscribeSupply _ident (Right params)

  forever $ do
    data' <- liftIO (receiveDataMessage conn)
    case data' of
      Text xs _ -> case decode xs of
        Nothing ->
          throwM (WebSocketRPCParseFailure ["server","text"] xs)
        Just x -> case x of
          Sub sub -> runSub sub
          Sup sup -> runSup sup
          Ping    -> pure ()
      Binary xs -> case decode xs of
        Nothing ->
          throwM (WebSocketRPCParseFailure ["server","binary"] xs)
        Just x -> case x of
          Sub sub -> runSub sub
          Sup sup -> runSup sup
          Ping    -> pure ()


-- | Note that this does not ping-pong.
rpcServerSimple :: forall sub sup rep com m
                 . ( MonadBaseControl IO m
                   , MonadIO m
                   )
                => RPCServer sub sup rep com m
                -> WebSocketsApp (Either (Reply rep) (Complete com)) (Either (Subscribe sub) (Supply sup)) (WebSocketServerRPCT sub sup m)
rpcServerSimple f = WebSocketsApp
  { onOpen = \send -> pure ()
  , onReceive = \send eSubSup -> do
      env <- getServerEnv

      let runSub :: Subscribe sub -> WebSocketServerRPCT sub sup m ()
          runSub (Subscribe RPCIdentified{_ident,_params}) = do

            let reply :: rep -> m ()
                reply rep =
                  let r = Reply RPCIdentified{_ident, _params = rep}
                  in  runWebSocketServerRPCT' env $ send (Left r)

                complete :: com -> m ()
                complete com =
                  let c = Complete RPCIdentified{_ident, _params = com}
                  in  runWebSocketServerRPCT' env $ send (Right c)

                cont :: Either sub sup -> m ()
                cont eSubSup = liftBaseWith $ \runInBase -> void $ Async.async $
                  void $ runInBase $ f RPCServerParams{reply,complete} eSubSup

            registerSubscribeSupply _ident cont
            runSubscribeSupply _ident (Left _params)

          runSup :: Supply sup -> WebSocketServerRPCT sub sup m ()
          runSup (Supply RPCIdentified{_ident,_params}) =
            case _params of
              Nothing     -> unregisterSubscribeSupply _ident -- FIXME this could bork the server if I `async` a routine thread
              Just params -> runSubscribeSupply _ident (Right params)

      case eSubSup of
        Left sub -> runSub sub
        Right sup -> runSup sup
  }



-- * Client


data RPCClientParams sup m = RPCClientParams
  { supply :: sup -> m () -- ^ dispatch a supply
  , cancel :: m ()        -- ^ cancel the RPC call
  }

data RPCClient sub sup rep com m = RPCClient
  { subscription :: !sub
  , onSubscribe  :: RPCClientParams sup m
                 -> m ()
  , onReply      :: RPCClientParams sup m
                 -> rep
                 -> m () -- ^ handle incoming reply
  , onComplete   :: com -> m () -- ^ handle finalized onComplete
  }


-- | May throw a 'WebSocketRPCParseFailure' if the opposing party sends bad data
rpcClient :: forall sub sup rep com m
           . ( ToJSON sub
             , ToJSON sup
             , FromJSON rep
             , FromJSON com
             , MonadIO m
             , MonadThrow m
             , MonadCatch m
             )
          => ((RPCClient sub sup rep com m -> WebSocketClientRPCT rep com m ()) -> WebSocketClientRPCT rep com m ())
          -> ClientAppT (WebSocketClientRPCT rep com m) ()
rpcClient userGo conn =
  let go :: RPCClient sub sup rep com m -> WebSocketClientRPCT rep com m ()
      go RPCClient{subscription,onSubscribe,onReply,onComplete} = do
        _ident <- freshRPCID

        liftIO (sendDataMessage conn (Text (encode (Subscribe RPCIdentified{_ident, _params = subscription})) Nothing))

        let supply :: sup -> m ()
            supply sup = liftIO (sendDataMessage conn (Text (encode (Supply RPCIdentified{_ident, _params = Just sup})) Nothing))

            cancel :: m ()
            cancel = liftIO (sendDataMessage conn (Text (encode (Supply RPCIdentified{_ident, _params = Nothing :: Maybe ()})) Nothing))

        lift (onSubscribe RPCClientParams{supply,cancel})

        registerReplyComplete _ident (onReply RPCClientParams{supply,cancel}) onComplete

        let runRep :: Reply rep -> WebSocketClientRPCT rep com m ()
            runRep (Reply RPCIdentified{_ident = _ident',_params})
              | _ident' == _ident = runReply _ident _params
              | otherwise         = pure () -- FIXME fail somehow legibly??

            runCom :: Complete com -> WebSocketClientRPCT rep com m ()
            runCom (Complete RPCIdentified{_ident = _ident', _params})
              | _ident' == _ident = do
                  runComplete _ident' _params -- NOTE don't use onComplete here because it might not exist later
                  unregisterReplyComplete _ident'
              | otherwise = pure ()

        forever $ do
          data' <- liftIO (receiveDataMessage conn)
          case data' of
            Text xs _ ->
              case decode xs of
                Nothing ->
                  throwM (WebSocketRPCParseFailure ["client","text"] xs)
                Just x -> case x of
                  Rep rep -> runRep rep
                  Com com -> runCom com
                  Pong    -> liftIO (sendDataMessage conn (Text (encode (Ping :: ClientToServer () ())) Nothing))
            Binary xs ->
              case decode xs of
                Nothing ->
                  throwM (WebSocketRPCParseFailure ["client","binary"] xs)
                Just x -> case x of
                  Rep rep -> runRep rep
                  Com com -> runCom com
                  Pong    -> liftIO (sendDataMessage conn (Text (encode (Ping :: ClientToServer () ())) Nothing))

  in  userGo go


-- | Note, does not support pingpong
rpcClientSimple :: forall sub sup rep com m
                 . ( MonadIO m
                   )
                => RPCClient sub sup rep com m
                -> WebSocketClientRPCT rep com m (WebSocketsApp (Either (Subscribe sub) (Supply sup)) (Either (Reply rep) (Complete com)) (WebSocketClientRPCT rep com m))
rpcClientSimple RPCClient{subscription,onSubscribe,onReply,onComplete} = do
  _ident <- freshRPCID
  pure WebSocketsApp
    { onOpen = \send -> do
        send $ Left $ Subscribe RPCIdentified{_ident, _params = subscription}

        env <- getClientEnv

        let supply :: sup -> m ()
            supply sup = runWebSocketClientRPCT' env $ send $ Right $ Supply RPCIdentified{_ident, _params = Just sup}

            cancel :: m ()
            cancel = runWebSocketClientRPCT' env $ send $ Right $ Supply RPCIdentified{_ident, _params = Nothing}

        lift (onSubscribe RPCClientParams{supply,cancel})

        registerReplyComplete _ident (onReply RPCClientParams{supply,cancel}) onComplete

    , onReceive = \send eRepCom -> do
        let runRep :: Reply rep -> WebSocketClientRPCT rep com m ()
            runRep (Reply RPCIdentified{_ident = _ident',_params})
              | _ident' == _ident = runReply _ident _params
              | otherwise         = pure () -- FIXME fail somehow legibly??

            runCom :: Complete com -> WebSocketClientRPCT rep com m ()
            runCom (Complete RPCIdentified{_ident = _ident', _params})
              | _ident' == _ident = do
                  runComplete _ident' _params -- NOTE don't use onComplete here because it might not exist later
                  unregisterReplyComplete _ident'
              | otherwise = pure ()

        case eRepCom of
          Left rep -> runRep rep
          Right com -> runCom com
    }



runClientAppTBackingOff :: (forall a. m a -> IO a)
                        -> String
                        -> Int
                        -> String
                        -> ClientAppT m ()
                        -> IO ()
runClientAppTBackingOff runM host port path app = do
  let app' = runClientAppT runM app
      second = 1000000

  spentWaiting <- newIORef (0 :: Int)

  let handleConnError :: SomeException -> IO ()
      handleConnError _ = do
        toWait <- readIORef spentWaiting
        let toWait' = 2 ^ toWait
        putStrLn $ "websocket disconnected - waiting " ++ show toWait' ++ " seconds before trying again..."
        writeIORef spentWaiting (toWait + 1)
        threadDelay $ second * toWait'
        loop

      attemptRun x =
        runClient host port path $ \conn -> do
          writeIORef spentWaiting 0
          x conn

      loop = attemptRun app' `catch` handleConnError

  loop

runWebSocketClientRPCTSimple  :: ( Monad m
                                 )
                              => (forall a. WebSocketClientRPCT rep com m a -> m a)
                              -> WebSocketsApp (Either (Subscribe sub) (Supply sup)) (Either (Reply rep) (Complete com)) (WebSocketClientRPCT rep com m)
                              -> WebSocketsApp (Either (Subscribe sub) (Supply sup)) (Either (Reply rep) (Complete com)) m
runWebSocketClientRPCTSimple runWS x = hoistWebSocketsApp runWS lift x


execWebSocketClientRPCTSimple  :: ( MonadBaseControl IO m
                                  )
                                => WebSocketsApp (Either (Subscribe sub) (Supply sup)) (Either (Reply rep) (Complete com)) (WebSocketClientRPCT rep com m)
                                -> m (WebSocketsApp (Either (Subscribe sub) (Supply sup)) (Either (Reply rep) (Complete com)) m)
execWebSocketClientRPCTSimple x = do
  env <- liftBaseWith $ \_ -> Client.newEnv

  let runWS = runWebSocketClientRPCT' env

  pure $ runWebSocketClientRPCTSimple runWS x


runWebSocketServerRPCTSimple :: ( Monad m
                                )
                             => (forall a. WebSocketServerRPCT sub sup m a -> m a)
                             -> WebSocketsApp (Either (Reply rep) (Complete com)) (Either (Subscribe sub) (Supply sup)) (WebSocketServerRPCT sub sup m)
                             -> WebSocketsApp (Either (Reply rep) (Complete com)) (Either (Subscribe sub) (Supply sup)) m
runWebSocketServerRPCTSimple runWS x = hoistWebSocketsApp runWS lift x


execWebSocketServerRPCTSimple  :: ( MonadBaseControl IO m
                                  )
                               =>    WebSocketsApp (Either (Reply rep) (Complete com)) (Either (Subscribe sub) (Supply sup)) (WebSocketServerRPCT sub sup m)
                               -> m (WebSocketsApp (Either (Reply rep) (Complete com)) (Either (Subscribe sub) (Supply sup)) m)
execWebSocketServerRPCTSimple x = do
  env <- liftBaseWith $ \_ -> Server.newEnv

  let runWS = runWebSocketServerRPCT' env

  pure $ runWebSocketServerRPCTSimple runWS x
