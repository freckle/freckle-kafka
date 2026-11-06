-- | Observability hooks for Kafka producers
--
-- By default, a producer created by 'Freckle.App.Kafka.Producer.createKafkaProducerPool'
-- only reports /local/ enqueue failures (the result of @produceMessage@).
-- Whether a message actually reached the broker is reported asynchronously by
-- librdkafka, through a delivery report, and client-level problems (broker
-- down, auth failure, ...) through an error callback. This module wraps both
-- so that failures can be logged and counted.
--
-- /Note: librdkafka only runs these callbacks when the producer is polled./
-- @hw-kafka-client@ polls after each @produceMessage@ and when the producer is
-- closed or flushed, but not in the background. A report for a message may
-- therefore be delayed until the next message is produced on the same
-- producer, or until the producer is closed.
module Freckle.App.Kafka.Producer.Hooks
  ( ProducerHooks (..)
  , loggingProducerHooks
  , producerHooksProperties
  ) where

import Prelude

import Blammo.Logging (Message ((:#)), logErrorNS, (.=))
import Control.Monad.Logger.Aeson (LoggingT)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Kafka.Producer
  ( DeliveryReport (..)
  , KafkaError
  , ProducerProperties
  , ProducerRecord (..)
  , TopicName (..)
  , deliveryCallback
  , errorCallback
  , setCallback
  )
import UnliftIO.Exception (handleAny)

-- | Actions to run on events reported by librdkafka
--
-- These run on a librdkafka thread, so they should be quick, and they are
-- called in the order they were combined with '<>'. An exception thrown by a
-- hook is swallowed, so a faulty hook can't stop delivery reports being
-- processed.
data ProducerHooks = ProducerHooks
  { onDeliveryReport :: DeliveryReport -> IO ()
  -- ^ Called once per message, with success or failure
  --
  -- Use this to count sent and failed events, for example.
  , onProducerError :: KafkaError -> String -> IO ()
  -- ^ Called for client-level errors, with librdkafka's message
  }

instance Semigroup ProducerHooks where
  a <> b =
    ProducerHooks
      { onDeliveryReport = \r -> onDeliveryReport a r *> onDeliveryReport b r
      , onProducerError = \e m -> onProducerError a e m *> onProducerError b e m
      }

instance Monoid ProducerHooks where
  mempty =
    ProducerHooks
      { onDeliveryReport = \_ -> pure ()
      , onProducerError = \_ _ -> pure ()
      }

-- | Hooks that log failures at error level, under the @kafka@ namespace
--
-- Hooks run in 'IO' on a librdkafka thread, so the caller supplies how to run
-- logging there, such as @runLoggerLoggingT logger@ from Blammo.
--
-- Successful deliveries are not logged. The event payload is never logged,
-- only the topic, partition and key.
loggingProducerHooks :: (LoggingT IO () -> IO ()) -> ProducerHooks
loggingProducerHooks runLogging =
  ProducerHooks
    { onDeliveryReport = \case
        DeliverySuccess {} -> pure ()
        DeliveryFailure record err ->
          runLogging
            $ logErrorNS "kafka"
            $ "Failed to deliver event"
              :# [ "topic" .= unTopicName (prTopic record)
                 , "partition" .= T.pack (show (prPartition record))
                 , "key" .= fmap (decodeUtf8With lenientDecode) (prKey record)
                 , "error" .= T.pack (show err)
                 ]
        NoMessageError err ->
          runLogging
            $ logErrorNS "kafka"
            $ "Delivery report without a message"
              :# ["error" .= T.pack (show err)]
    , onProducerError = \err message ->
        runLogging
          $ logErrorNS "kafka"
          $ "Kafka producer error"
            :# ["error" .= T.pack (show err), "message" .= T.pack message]
    }

-- | Register the hooks as callbacks on a producer
--
-- Replaces the default delivery callback, which ignores reports.
producerHooksProperties :: ProducerHooks -> ProducerProperties
producerHooksProperties hooks =
  setCallback (deliveryCallback $ safely . onDeliveryReport hooks)
    <> setCallback (errorCallback $ \e m -> safely $ onProducerError hooks e m)
 where
  safely :: IO () -> IO ()
  safely = handleAny $ \_ -> pure ()
