module Network.WebSockets.RPC where

import Network.WebSockets.RPC.Types (WebSocketRPCException (..))
import Network.WebSockets (acceptRequest, receiveDataMessage, DataMessage (Text, Binary))
import Network.Wai.Trans (ServerAppT)
import Data.Aeson (decode, encode)

import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Catch (throwM)


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
  , complete     :: com -> m () -- ^ handle finalized completion
  }




rpcServer  :: ( ToJSON rep
              , ToJSON com
              , FromJSON sub
              , FromJSON sup
              , MonadIO m
              )
            => RPCServer sub sup rep com m
            -> ServerAppT (WebSocketServerRPCT m)
rpcServer f pendingConn = do
  conn <- liftIO (acceptRequest pendingConn)
  data' <- liftIO (receiveDataMessage conn)
  case data' of
    Text xs -> case decode xs of
      Nothing -> throwM (WebSocketRPCParseFailure xs)
      Just x -> case x of
        Sub sub@(Subscribe (RPCIdentified {_ident,_params})) ->
          let reply rep =
                let r = Reply (RPCIdentified {_ident, _params = rep})
                in  liftIO (sendDataMessage conn (Text (encode r)))
              complete com =
                let c = Complete (RPCIdentified {_ident, _params = com})
                in  liftIO (sendDataMessage conn (Text (encode c)))
        Sup sup@(Supply    (RPCIdentified {_ident,_params})) ->
    Binary xs -> case decode xs of
      Nothing -> throwM (WebSocketRPCParseFailure xs)
