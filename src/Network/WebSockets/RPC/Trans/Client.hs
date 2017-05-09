{-# LANGUAGE
    NamedFieldPuns
  , DeriveGeneric
  , DeriveDataTypeable
  , DeriveFunctor
  , GeneralizedNewtypeDeriving
  , FlexibleInstances
  , MultiParamTypeClasses
  , UndecidableInstances
  #-}

module Network.WebSockets.RPC.Trans.Client
  ( WebSocketClientRPCT
  , runWebSocketClientRPCT'
  , getClientEnv
  , execWebSocketClientRPCT
  , -- * Utilities
    freshRPCID
  , registerReplyComplete
  , unregisterReplyComplete
  , runReply
  , runComplete
  , newEnv
  , Env
  ) where

import GHC.Generics (Generic)
import Data.Data (Typeable)

import Network.WebSockets.RPC.Types (RPCID, getRPCID)

import Control.Concurrent.STM.TVar (newTVarIO, readTVar, readTVarIO, writeTVar, TVar)
import Control.Concurrent.STM (atomically)

import Control.Monad.State.Class (MonadState)
import Control.Monad.Writer.Class (MonadWriter)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans (MonadTrans (lift))
import Control.Monad.Reader.Class (MonadReader (ask, local))
import Control.Monad.Reader (ReaderT (ReaderT))
import Control.Monad.Catch (MonadThrow, MonadCatch, MonadMask)

import Data.IntMap.Lazy (IntMap)
import qualified Data.IntMap.Lazy as IntMap


data Conts rep com m = Conts
  { reply    :: rep -> m ()
  , complete :: com -> m ()
  } deriving (Generic, Typeable)

data Env rep com m = Env
  { rpcIdentVar :: TVar RPCID
  , rpcContsVar :: TVar (IntMap (Conts rep com m))
  }


newEnv :: IO (Env rep com m)
newEnv = do
  rpcIdentVar <- newTVarIO minBound
  rpcContsVar <- newTVarIO mempty
  pure Env{rpcIdentVar, rpcContsVar}


newtype WebSocketClientRPCT rep com m a = WebSocketClientRPCT
  { runWebSocketClientRPCT :: ReaderT (Env rep com m) m a
  } deriving ( Generic, Typeable, Functor, Applicative, Monad
             , MonadState s, MonadWriter w, MonadIO, MonadThrow, MonadCatch, MonadMask
             )

runWebSocketClientRPCT' :: Env rep com m -> WebSocketClientRPCT rep com m a -> m a
runWebSocketClientRPCT' env (WebSocketClientRPCT (ReaderT f)) = f env

getClientEnv :: Applicative m => WebSocketClientRPCT rep com m (Env rep com m)
getClientEnv = WebSocketClientRPCT (ReaderT (\env -> pure env))

execWebSocketClientRPCT :: MonadIO m => WebSocketClientRPCT rep com m a -> m a
execWebSocketClientRPCT f = do
  env <- liftIO newEnv
  runWebSocketClientRPCT' env f

instance MonadTrans (WebSocketClientRPCT rep com) where
  lift x = WebSocketClientRPCT (ReaderT (const x))

instance MonadReader r m => MonadReader r (WebSocketClientRPCT rep com m) where
  ask                                       = WebSocketClientRPCT (ReaderT (const ask))
  local f (WebSocketClientRPCT (ReaderT g)) = WebSocketClientRPCT (ReaderT (\env -> local f (g env)))

freshRPCID :: MonadIO m => WebSocketClientRPCT rep com m RPCID
freshRPCID =
  let f Env{rpcIdentVar} =
        let go = do rpcId <- readTVar rpcIdentVar
                    writeTVar rpcIdentVar (succ rpcId)
                    pure rpcId
        in  liftIO (atomically go)
  in  WebSocketClientRPCT (ReaderT f)

registerReplyComplete :: MonadIO m => RPCID -> (rep -> m ()) -> (com -> m ()) -> WebSocketClientRPCT rep com m ()
registerReplyComplete rpcId reply complete =
  let f Env{rpcContsVar} = liftIO $ do
        conts <- readTVarIO rpcContsVar
        atomically (writeTVar rpcContsVar (IntMap.insert (getRPCID rpcId) Conts{reply,complete} conts))
  in  WebSocketClientRPCT (ReaderT f)

unregisterReplyComplete :: MonadIO m => RPCID -> WebSocketClientRPCT rep com m ()
unregisterReplyComplete rpcId =
  let f Env{rpcContsVar} = liftIO $ do
        conts <- readTVarIO rpcContsVar
        atomically (writeTVar rpcContsVar (IntMap.delete (getRPCID rpcId) conts))
  in  WebSocketClientRPCT (ReaderT f)


runReply :: MonadIO m => RPCID -> rep -> WebSocketClientRPCT rep com m ()
runReply rpcId rep =
  let f Env{rpcContsVar} = do
        conts <- liftIO (readTVarIO rpcContsVar)
        case IntMap.lookup (getRPCID rpcId) conts of
          Nothing           -> pure () -- TODO throw notfound warning?
          Just Conts{reply} -> reply rep
  in  WebSocketClientRPCT (ReaderT f)

runComplete :: MonadIO m => RPCID -> com -> WebSocketClientRPCT rep com m ()
runComplete rpcId rep =
  let f Env{rpcContsVar} = do
        conts <- liftIO (readTVarIO rpcContsVar)
        case IntMap.lookup (getRPCID rpcId) conts of
          Nothing              -> pure () -- TODO throw notfound warning?
          Just Conts{complete} -> complete rep
  in  WebSocketClientRPCT (ReaderT f)
