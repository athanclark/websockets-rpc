{-# LANGUAGE
    RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  #-}

module Network.WebSockets.RPC where

import Network.WebSockets.RPC.Trans.Server ( WebSocketServerRPCT, runWebSocketServerRPCT', getServerEnv
                                           , registerSubscribeSupply, runSubscribeSupply, unregisterSubscribeSupply)
import Network.WebSockets.RPC.Types ( WebSocketRPCException (..), Subscribe (..), Supply (..), Reply (..), Complete (..)
                                    , ClientToServer (Sub, Sup)
                                    , RPCIdentified (..)
                                    )
import Network.WebSockets (acceptRequest, receiveDataMessage, sendDataMessage, DataMessage (Text, Binary))
import Network.Wai.Trans (ServerAppT)
import Data.Aeson (ToJSON, FromJSON, decode, encode)

import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Catch (MonadThrow, throwM)
import Control.Monad.Trans (lift)


data RPCServerParams rep com m = RPCServerParams
  { reply    :: rep -> m () -- ^ dispatch a reply
  , complete :: com -> m () -- ^ dispatch a completion
  }

type RPCServer sub sup rep com m
  =  RPCServerParams rep com m
  -> Either sub sup -- ^ handle incoming message
  -> m ()


data RPCClientParams sup m = RPCClientParams
  { supply :: sup -> m () -- ^ dispatch a supply
  , cancel :: m ()        -- ^ cancel the RPC call
  }

data RPCClient sub sup rep com m = RPCClient
  { subscription :: !sub
  , replier      :: RPCClientParams sup m
                 -> rep -- ^ handle incoming reply
                 -> m ()
  , completion   :: com -> m () -- ^ handle finalized completion
  }




rpcServer  :: forall rep com sub sup m
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
  data' <- liftIO (receiveDataMessage conn)
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
                     runWebSocketServerRPCT' env (unregisterSubscribeSupply _ident)

            cont :: Either sub sup -> m ()
            cont = f RPCServerParams{reply,complete}

        registerSubscribeSupply _ident cont
        lift (cont (Left _params)) -- runSubscribeSupply _ident (Left _params) -- FIXME Do I really even need Left?

      runSup :: Supply sup -> WebSocketServerRPCT sub sup m ()
      runSup (Supply RPCIdentified{_ident,_params}) =
        case _params of
          Nothing     -> unregisterSubscribeSupply _ident -- FIXME this could bork the server if I `async` a routine thread
          Just params -> runSubscribeSupply _ident (Right params)

  case data' of
    Text xs -> case decode xs of
      Nothing -> throwM (WebSocketRPCParseFailure xs)
      Just x -> case x of
        Sub sub -> runSub sub
        Sup sup -> runSup sup
    Binary xs -> case decode xs of
      Nothing -> throwM (WebSocketRPCParseFailure xs)
      Just x -> case x of
        Sub sub -> runSub sub
        Sup sup -> runSup sup
