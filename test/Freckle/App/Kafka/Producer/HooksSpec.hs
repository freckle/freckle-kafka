module Freckle.App.Kafka.Producer.HooksSpec
  ( spec
  ) where

import Prelude

import Control.Exception (bracket, throwIO)
import Control.Monad.Logger.Aeson (LogLevel (..), LoggingT, runLoggingT)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Freckle.App.Kafka.Producer.Hooks
import Kafka.Consumer.Types (Offset (..))
import Kafka.Producer
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = do
  describe "ProducerHooks" $ do
    it "runs both hooks, in order, when combined" $ do
      ran <- newIORef ([] :: [String])
      let hook name =
            mempty {onDeliveryReport = \_ -> modifyIORef' ran (name :)}

      onDeliveryReport (hook "first" <> hook "second") report

      readIORef ran `shouldReturn` ["second", "first"]

  describe "loggingProducerHooks" $ do
    it "logs a delivery failure with topic and key, but not the payload" $ do
      (run, logged) <- captureLogs

      onDeliveryReport (loggingProducerHooks run)
        $ DeliveryFailure record (KafkaError "boom")

      readIORef logged >>= \case
        [(source, level, message)] -> do
          source `shouldBe` "kafka"
          level `shouldBe` LevelError
          message `shouldSatisfy` T.isInfixOf "Failed to deliver event"
          message `shouldSatisfy` T.isInfixOf "answers"
          message `shouldSatisfy` T.isInfixOf "student-123"
          message `shouldSatisfy` (not . T.isInfixOf "SECRET-PAYLOAD")
        other ->
          expectationFailure $ "Expected one log, got " <> show (length other)

    it "does not log a successful delivery" $ do
      (run, logged) <- captureLogs

      onDeliveryReport (loggingProducerHooks run)
        $ DeliverySuccess record (Offset 0)

      readIORef logged `shouldReturn` []

    it "logs a client error" $ do
      (run, logged) <- captureLogs

      onProducerError (loggingProducerHooks run) (KafkaError "boom") "all down"

      readIORef logged >>= \case
        [(source, level, message)] -> do
          source `shouldBe` "kafka"
          level `shouldBe` LevelError
          message `shouldSatisfy` T.isInfixOf "Kafka producer error"
          message `shouldSatisfy` T.isInfixOf "all down"
        other ->
          expectationFailure $ "Expected one log, got " <> show (length other)

  -- These use a real producer, but no broker: nothing listens on port 1, so
  -- the message sits in librdkafka's queue until message.timeout.ms, then is
  -- reported as failed. 'closeProducer' polls until the queue is empty, so
  -- the delivery callback has run by the time 'withProducer' returns.
  describe "producerHooksProperties" $ do
    it "reports a failed delivery to the hook" $ do
      reports <- newIORef []
      let hooks =
            mempty {onDeliveryReport = \r -> modifyIORef' reports (r :)}

      withProducer (unreachable hooks) $ \producer ->
        produceMessage producer record `shouldReturn` Nothing

      readIORef reports >>= \case
        [DeliveryFailure failed _] -> do
          prTopic failed `shouldBe` prTopic record
          prKey failed `shouldBe` prKey record
          prValue failed `shouldBe` prValue record
        other ->
          expectationFailure
            $ "Expected one delivery failure, got " <> show other

    it "survives a hook that throws" $ do
      let hooks =
            mempty {onDeliveryReport = \_ -> throwIO $ userError "hook failed"}

      withProducer (unreachable hooks) $ \producer ->
        produceMessage producer record `shouldReturn` Nothing

record :: ProducerRecord
record =
  ProducerRecord
    { prTopic = "answers"
    , prPartition = UnassignedPartition
    , prKey = Just "student-123"
    , prValue = Just "SECRET-PAYLOAD"
    , prHeaders = mempty
    }

report :: DeliveryReport
report = NoMessageError $ KafkaError "boom"

-- | A runner for 'loggingProducerHooks', and what it has logged so far
captureLogs
  :: IO
      ( LoggingT IO () -> IO ()
      , IORef [(Text, LogLevel, Text)]
      )
captureLogs = do
  logged <- newIORef []
  let run action =
        runLoggingT action $ \_ source level message ->
          modifyIORef' logged ((source, level, T.pack (show message)) :)
  pure (run, logged)

-- | Producer settings for a broker that is not there, failing fast
unreachable :: ProducerHooks -> ProducerProperties
unreachable hooks =
  brokersList ["localhost:1"]
    -- Not 'sendTimeout': in hw-kafka-client 5.3.0 that sets a topic-level
    -- property which is never applied, so messages would wait out the default
    -- 5 minutes. The global property works.
    <> extraProp "delivery.timeout.ms" "500"
    -- librdkafka logs every refused connection to stderr; only log emergencies
    <> logLevel KafkaLogEmerg
    <> producerHooksProperties hooks

-- | Run an action with a producer, and flush it afterwards
--
-- Fails, rather than hangs, if that takes more than 20 seconds.
withProducer :: ProducerProperties -> (KafkaProducer -> IO a) -> IO a
withProducer props action =
  maybe (fail "Producer was not flushed within 20 seconds") pure
    =<< timeout (20 * 1000000) (bracket open closeProducer action)
 where
  open = either throwIO pure =<< newProducer props
