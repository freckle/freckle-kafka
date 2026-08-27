## [_Unreleased_](https://github.com/freckle/freckle-kafka/compare/v0.1.0.0...main)

## [v0.1.0.0](https://github.com/freckle/freckle-kafka/compare/v0.0.0.4...v0.1.0.0)

- Add `withKafkaProducerPool`, which creates a Kafka producer pool and
  closes it with `Pool.destroyAllResources` once the given action
  completes. Prefer this to `createKafkaProducerPool`, which leaves the
  pool open for the caller to close.
- Generalize `createKafkaProducerPool` from `IO` to any `MonadIO`

## [v0.0.0.4](https://github.com/freckle/freckle-kafka/tree/v0.0.0.4)

Changed source repository

## [v0.0.0.3](https://github.com/freckle/freckle-app/compare/freckle-kafka-v0.0.0.2...freckle-kafka-v0.0.0.3)

Add `produce`

## [v1.21.1.0](https://github.com/freckle/freckle-app/compare/freckle-kafka-v0.0.0.1...freckle-kafka-v0.0.0.2)

Add `Freckle.App.Kafka.Consumer.runConsumerBatched`

## [v0.0.0.1](https://github.com/freckle/freckle-app/compare/freckle-kafka-v0.0.0.0...freckle-kafka-v0.0.0.1)

Drop `relude` dependency

## [v0.0.0.0](https://github.com/freckle/freckle-app/tree/freckle-kafka-v0.0.0.0/freckle-kafka)

First release, sprouted from `freckle-app-1.18.2.0`.

Changes from `freckle-app`:

- `produceKeyedOnAsync` has been removed; you may substitute the definition
  `(\prTopic values -> void . async . produceKeyedOn prTopic values)`.

- `runConsumer` has been altered; you may recover the original behavior by
  changing `runConsumer pollTimeout onMessage` to
  `withTraceContext $ immortalCreateLogged $ runConsumer pollTimeout onMessage`.
