{-# LANGUAGE
    RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  #-}

module Network.WebSockets.RPC
  ( -- * Server
    RPCServerParams (..), RPCServer, rpcServer
  , -- * Client
    RPCClientParams (..), RPCClient (..), rpcClient
  , -- * Re-Exports
    WebSocketServerRPCT, execWebSocketServerRPCT, WebSocketClientRPCT, execWebSocketClientRPCT
  , WebSocketRPCException (..)
  ) where

import Network.WebSockets.RPC.Trans.Server ( WebSocketServerRPCT, runWebSocketServerRPCT', getServerEnv, execWebSocketServerRPCT
                                           , registerSubscribeSupply, runSubscribeSupply, unregisterSubscribeSupply)
import Network.WebSockets.RPC.Trans.Client ( WebSocketClientRPCT, runWebSocketClientRPCT', getClientEnv, execWebSocketClientRPCT
                                           , registerReplyComplete, runReply, runComplete, unregisterReplyComplete
                                           , freshRPCID
                                           )
import Network.WebSockets.RPC.Types ( WebSocketRPCException (..), Subscribe (..), Supply (..), Reply (..), Complete (..)
                                    , ClientToServer (Sub, Sup, Ping), ServerToClient (Rep, Com, Pong)
                                    , RPCIdentified (..)
                                    )
import Network.WebSockets (acceptRequest, receiveDataMessage, sendDataMessage, DataMessage (Text, Binary))
import Network.Wai.Trans (ServerAppT, ClientAppT)
import Data.Aeson (ToJSON, FromJSON, decode, encode)

import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Catch (MonadThrow, throwM)
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
              )
            => RPCServer sub sup rep com m
            -> ServerAppT (WebSocketServerRPCT sub sup m)
rpcServer f pendingConn = do
  conn <- liftIO (acceptRequest pendingConn)
  void $ liftIO $ Async.async $ forever $ do
    sendDataMessage conn (Text (encode (Pong :: ServerToClient () ())))
    threadDelay 1000000

  let runSub :: Subscribe sub -> WebSocketServerRPCT sub sup m ()
      runSub (Subscribe RPCIdentified{_ident,_params}) = do
        env <- getServerEnv

        let reply :: rep -> m ()
            reply rep =
              let r = Reply RPCIdentified{_ident, _params = rep}
              in  liftIO (sendDataMessage conn (Text (encode r)))

            complete :: com -> m ()
            complete com =
              let c = Complete RPCIdentified{_ident, _params = com}
              in  do liftIO (sendDataMessage conn (Text (encode c)))
                     -- runWebSocketServerRPCT' env (unregisterSubscribeSupply _ident)

            cont :: Either sub sup -> m ()
            cont = f RPCServerParams{reply,complete}

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
      Text xs -> case decode xs of
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




-- * Client


data RPCClientParams sup m = RPCClientParams
  { supply :: sup -> m () -- ^ dispatch a supply
  , cancel :: m ()        -- ^ cancel the RPC call
  }

data RPCClient sub sup rep com m = RPCClient
  { subscription :: !sub
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
             )
          => ((RPCClient sub sup rep com m -> WebSocketClientRPCT rep com m ()) -> WebSocketClientRPCT rep com m ())
          -> ClientAppT (WebSocketClientRPCT rep com m) ()
rpcClient userGo conn =
  let go RPCClient{subscription,onReply,onComplete} = do
        _ident <- freshRPCID

        liftIO (sendDataMessage conn (Text (encode (Subscribe RPCIdentified{_ident, _params = subscription}))))

        env <- getClientEnv

        let supply :: sup -> m ()
            supply sup = liftIO (sendDataMessage conn (Text (encode (Supply RPCIdentified{_ident, _params = Just sup}))))

            cancel :: m ()
            cancel = do
              liftIO (sendDataMessage conn (Text (encode (Supply RPCIdentified{_ident, _params = Nothing :: Maybe ()}))))
              runWebSocketClientRPCT' env (unregisterReplyComplete _ident)

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
            Text xs ->
              case decode xs of
                Nothing ->
                  throwM (WebSocketRPCParseFailure ["client","text"] xs)
                Just x -> case x of
                  Rep rep -> runRep rep
                  Com com -> runCom com
                  Pong    -> liftIO (sendDataMessage conn (Text (encode (Ping :: ClientToServer () ()))))
            Binary xs ->
              case decode xs of
                Nothing ->
                  throwM (WebSocketRPCParseFailure ["client","binary"] xs)
                Just x -> case x of
                  Rep rep -> runRep rep
                  Com com -> runCom com
                  Pong    -> liftIO (sendDataMessage conn (Text (encode (Ping :: ClientToServer () ()))))

  in  userGo go
