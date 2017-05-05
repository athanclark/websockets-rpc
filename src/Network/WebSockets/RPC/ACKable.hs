{-# LANGUAGE
    RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  , OverloadedStrings
  #-}

module Network.WebSockets.RPC.ACKable
  ( ackableRPCServer
  , ackableRPCClient
  , ACKable (..)
  ) where

import Network.WebSockets.RPC
import Data.UUID (UUID, toString, fromString)
import Data.UUID.V4 (nextRandom)
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Hashable (Hashable)
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), (.=), object)
import Data.Aeson.Types (typeMismatch, Value (Object))
import Control.Applicative ((<|>))
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import qualified Control.Concurrent.Async as Async
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (newTVarIO, readTVarIO, readTVar, writeTVar, modifyTVar, TVar)


data ACKable owner a = ACKable
  { ackableID    :: UUID
  , ackableOwner :: owner
  , ackableData  :: Maybe a -- ^ 'Data.Maybe.Nothing' represents an ACK
  }

instance (ToJSON owner, ToJSON a) => ToJSON (ACKable owner a) where
  toJSON ACKable{ackableID,ackableOwner,ackableData} = object
    [ "id" .= toString ackableID
    , "owner" .= ackableOwner
    , "data" .= ackableData
    ]

instance (FromJSON owner, FromJSON a) => FromJSON (ACKable owner a) where
  parseJSON (Object o) = do
    id' <- o .: "id"
    case fromString id' of
      Nothing -> fail "can't parse id"
      Just ackableID -> do
        ackableOwner <- o .: "owner"
        ackableData  <- o .: "data"
        pure ACKable
          { ackableID
          , ackableOwner
          , ackableData
          }
  parseJSON x = typeMismatch "ACKable" x



ack :: UUID -> owner -> ACKable owner a
ack ackableID ackableOwner = ACKable
  { ackableID
  , ackableOwner
  , ackableData = Nothing
  }




ackableRPCServer :: forall sub sup rep com m owner
                  . ( MonadIO m
                    , Eq owner
                    , Hashable owner
                    )
                 => (forall a. m a -> IO a)
                 -> owner
                 -> RPCServer sub sup rep com m
                 -> m (RPCServer (ACKable owner sub) (ACKable owner sup) (ACKable owner rep) com m)
ackableRPCServer runM serverOwner rpc = do
  replyMailbox <- liftIO $ newTVarIO HM.empty
  ownerPending <- liftIO $ newTVarIO (HM.empty :: HM.HashMap owner (HS.HashSet UUID))

  pure $ \RPCServerParams{reply,complete} eSubSup -> do
    let params :: owner -> RPCServerParams rep com m
        params clientOwner = RPCServerParams
          { reply = \r -> do
              ackableID <- liftIO nextRandom
              let op = do
                    liftIO $ putStrLn $ "Replying: " ++ show ackableID
                    reply ACKable
                      { ackableID
                      , ackableOwner = serverOwner
                      , ackableData = Just r
                      }
              liftIO $ do
                expBackoff <- mkBackoff (runM op) $ do
                  replies <- readTVarIO replyMailbox
                  putStrLn $ "Deleting: " ++ show ackableID
                  atomically $ do
                    modifyTVar replyMailbox $ HM.delete ackableID
                    modifyTVar ownerPending $ HM.delete clientOwner
                  case HM.lookup ackableID replies of
                    Nothing -> pure ()
                    Just (_,expBackoff) -> Async.cancel expBackoff
                atomically $ do
                  modifyTVar replyMailbox $ HM.insert ackableID (r, expBackoff)
                  modifyTVar ownerPending $ HM.insertWith HS.union clientOwner (HS.singleton ackableID)
                keys <- HM.keys <$> readTVarIO replyMailbox
                print keys
              op
          , complete
          }

    case eSubSup of
      Left ACKable{ackableID,ackableOwner,ackableData} -> case ackableData of
        Nothing -> liftIO $ putStrLn $ "Somehow was provided a Sub ACK: " ++ show ackableID
        Just sub -> rpc (params ackableOwner) (Left sub)
      Right ACKable{ackableID,ackableOwner,ackableData} ->
        case ackableData of
          Nothing -> liftIO $ do
            mExpBackoff <- atomically $ do
              replies <- readTVar replyMailbox
              owners <- readTVar ownerPending
              case HM.lookup ackableID replies of
                Nothing -> pure Nothing
                Just (_,expBackoff) -> do
                  writeTVar replyMailbox $ HM.delete ackableID replies
                  writeTVar ownerPending $ HM.adjust (HS.delete ackableID) ackableOwner owners
                  pure (Just expBackoff)
            keys <- HM.keys <$> readTVarIO replyMailbox
            putStrLn $ "ACK keys: " ++ show keys
            case mExpBackoff of
              Nothing -> putStrLn $ "Somehow received an ACK that doesn't exist: " ++ show ackableID
              Just expBackoff -> Async.cancel expBackoff

          Just sup -> do
            liftIO $ putStrLn $ "Acknowleding: " ++ show ackableID
            reply (ack ackableID serverOwner)
            rpc (params ackableOwner) (Right sup)



ackableRPCClient :: forall sub sup rep com m owner
                  . ( MonadIO m
                    , Eq owner
                    , Hashable owner
                    )
                 => (forall a. m a -> IO a)
                 -> owner
                 -> RPCClient sub sup rep com m
                 -> m (RPCClient (ACKable owner sub) (ACKable owner sup) (ACKable owner rep) com m)
ackableRPCClient runM clientOwner RPCClient{subscription,onSubscribe,onReply,onComplete} = do
  supplyMailbox <- liftIO $ newTVarIO HM.empty
  ownerPending <- liftIO $ newTVarIO (HM.empty :: HM.HashMap owner (HS.HashSet UUID))


  let ackParams :: Maybe owner -> RPCClientParams (ACKable owner sup) m -> RPCClientParams sup m
      ackParams mOwner RPCClientParams{supply,cancel} = RPCClientParams
        { supply = \s -> do
            ackableID <- liftIO nextRandom
            let op = do
                  liftIO $ putStrLn $ "Supplying: " ++ show ackableID
                  supply ACKable
                    { ackableID
                    , ackableOwner = clientOwner
                    , ackableData = Just s
                    }
            liftIO $ do
              expBackoff <- mkBackoff (runM op) $ do
                supplies <- readTVarIO supplyMailbox
                atomically $ do
                  modifyTVar supplyMailbox $ HM.delete ackableID
                  case mOwner of
                    Nothing -> pure ()
                    Just serverOwner -> modifyTVar ownerPending $ HM.delete serverOwner
                case HM.lookup ackableID supplies of
                  Nothing -> pure () -- deleting self
                  Just (_,expBackoff) -> Async.cancel expBackoff
              atomically $ do
                modifyTVar supplyMailbox $ HM.insert ackableID (s,expBackoff)
                case mOwner of
                  Nothing -> pure ()
                  Just serverOwner -> modifyTVar ownerPending $ HM.insertWith HS.union serverOwner (HS.singleton ackableID)
            op
        , cancel
        }
  ackableID <- liftIO nextRandom
  pure RPCClient
    { subscription = ACKable
        { ackableID
        , ackableOwner = clientOwner
        , ackableData = Just subscription
        }
    , onSubscribe = onSubscribe . ackParams Nothing
    , onReply = \params ACKable{ackableID,ackableData,ackableOwner} -> case ackableData of
        Nothing -> liftIO $ do
          mExpBackoff <- atomically $ do
            supplies <- readTVar supplyMailbox
            owners <- readTVar ownerPending
            case HM.lookup ackableID supplies of
              Nothing -> pure Nothing
              Just (_,expBackoff) -> do
                writeTVar supplyMailbox $ HM.delete ackableID supplies
                writeTVar ownerPending $ HM.adjust (HS.delete ackableID) ackableOwner owners
                pure (Just expBackoff)
          case mExpBackoff of
            Nothing -> putStrLn $ "Somehow received an ACK that doesn't exist: " ++ show ackableID
            Just expBackoff -> Async.cancel expBackoff
        Just rep -> do
          liftIO $ putStrLn $ "Acknowledging: " ++ show ackableID
          (supply params) (ack ackableID clientOwner)
          onReply (ackParams (Just ackableOwner) params) rep
    , onComplete
    }




second = 1000000
minute = 60 * second
hour = 60 * minute
day = 24 * hour
week = 7 * day

mkBackoff :: IO a -- ^ Invoked each attempt
          -> IO () -- ^ on quit
          -> IO (Async.Async a)
mkBackoff op x = do
  spentWaiting <- newIORef (0 :: Int)
  async $ do
    toWait <- readIORef spentWaiting
    writeIORef spentWaiting (toWait + 1)
    let toWait' = 2 ^ toWait
        soFar = sum $ (\x -> (2 ^ x) * second) <$> [0..toWait]

    when (soFar > week) x

    threadDelay $ second * (toWait' + 10)
    op
