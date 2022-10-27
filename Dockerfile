FROM python:3-slim-bullseye

## Kafka + Kerberos/SASL
RUN apt-get update && \
    apt-get install -y librdkafka1 \
                       krb5-user \
                       libsasl2-modules-gssapi-mit \
                       librdkafka-dev \
                       libsasl2-dev \
                       libkrb5-dev \
                       libssl-dev \
                       g++ && \
    pip install --no-cache-dir -I --upgrade pip && \
    pip install --no-cache-dir -I requests-kerberos==0.13.0 &&  \
    pip install --no-cache-dir -I confluent-kafka[avro]==1.7.0 --no-binary=confluent-kafka && \
    apt-get -y remove libkrb5-dev libsasl2-dev librdkafka-dev libssl-dev g++ && \
    apt-get -y autoremove && \
    apt-get -y clean
