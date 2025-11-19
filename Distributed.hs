-- Allows Generic, for auto-generation of serialization code
{-# LANGUAGE DeriveGeneric #-}
-- Allows automatic derivation of e.g. Monad
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- Allows automatic creation of Lenses for ServerState
{-# LANGUAGE TemplateHaskell #-}

-- Objects have to be binary to send over the network
-- For auto-derivation of serialization
-- For safe serialization

import Control.Concurrent (threadDelay)
import Control.Distributed.Process
  ( Process,
    ProcessId,
    expect,
    getSelfPid,
    match,
    receiveWait,
    say,
    send,
    spawnLocal,
  )
import Control.Distributed.Process.Node (initRemoteTable, newLocalNode, runProcess)
import Control.Lens (makeLenses, (%%=), (+=))
import Control.Monad (forever, replicateM)
import Control.Monad.RWS.Strict
  ( MonadReader,
    MonadState,
    MonadWriter,
    RWS,
    ask,
    execRWS,
    liftIO,
    tell,
  )
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Network.Transport.TCP (createTransport, defaultTCPAddr, defaultTCPParameters)
import System.Random (Random, StdGen, newStdGen, randomR)

data BingBong = Bing | Bong
  deriving (Show, Generic, Typeable)

data Message = Message {senderOf :: ProcessId, recipientOf :: ProcessId, msg :: BingBong}
  deriving (Show, Generic, Typeable)

data Tick = Tick deriving (Show, Generic, Typeable)

instance Binary BingBong

instance Binary Message

instance Binary Tick

data ServerState = ServerState
  { _bingCount :: Int,
    _bongCount :: Int,
    _randomGen :: StdGen
  }
  deriving (Show)

makeLenses ''ServerState

data ServerConfig = ServerConfig
  { myId :: ProcessId,
    peers :: [ProcessId]
  }
  deriving (Show)

newtype ServerAction a = ServerAction {runAction :: RWS ServerConfig [Message] ServerState a}
  deriving (Functor, Applicative, Monad, MonadState ServerState, MonadWriter [Message], MonadReader ServerConfig)

tickHandler :: Tick -> ServerAction ()
tickHandler Tick = do
  ServerConfig myPid peers <- ask
  random <- randomWithin (0, length peers - 1)
  let peer = peers !! random
  sendBingBongTo peer Bing

msgHandler :: Message -> ServerAction ()
msgHandler (Message sender recipient Bing) = do
  bingCount += 1
  sendBingBongTo sender Bong
msgHandler (Message sender recipient Bong) = do
  bongCount += 1

sendBingBongTo :: ProcessId -> BingBong -> ServerAction ()
sendBingBongTo recipient bingbong = do
  ServerConfig myId _ <- ask
  tell [Message myId recipient bingbong]

randomWithin :: (Random r) => (r, r) -> ServerAction r
randomWithin bounds = randomGen %%= randomR bounds

runServer :: ServerConfig -> ServerState -> Process ()
runServer config state = do
  let run handler msg = return $ execRWS (runAction $ handler msg) config state
  (state', outputMessages) <-
    receiveWait
      [ match $ run msgHandler,
        match $ run tickHandler
      ]
  say $ "Current state: " ++ show state'
  mapM_ (\msg -> send (recipientOf msg) msg) outputMessages
  runServer config state'

spawnServer :: Process ProcessId
spawnServer = spawnLocal $ do
  myPid <- getSelfPid
  otherPids <- expect
  spawnLocal $ forever $ do
    liftIO $ threadDelay (10 ^ 6)
    send myPid Tick
  randomGen <- liftIO newStdGen
  runServer (ServerConfig myPid otherPids) (ServerState 0 0 randomGen)

spawnServers :: Int -> Process ()
spawnServers count = do
  pids <- replicateM count spawnServer
  mapM_ (`send` pids) pids

main :: IO String
main = do
  Right transport <- createTransport (defaultTCPAddr "localhost" "0") defaultTCPParameters
  backendNode <- newLocalNode transport initRemoteTable
  runProcess backendNode (spawnServers 10)
  putStrLn "Push enter to exit"
  getLine
