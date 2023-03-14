use anyhow::Result;
use opentelemetry_otlp::WithExportConfig;
use std::time::Duration;
use tokio::signal;
use tokio::sync::watch;
use tracing::{event, span, Level};

use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt};

mod aws;
mod notion_api;
mod settings;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    set_up_logging()?;

    // let (send, mut recv): (Sender<()>, _) = channel(1);
    let (tx, rx) = watch::channel(());

    // Env vars! -----------------------------------
    let mut retry_wait_seconds = 1;
    let settings_map = loop {
        let settings_map = settings::get_settings();
        match settings_map {
            Err(error) => {
                println!("Error obtaining settings");
                println!("{:#?}", error);
                tokio::time::sleep(Duration::from_secs(retry_wait_seconds)).await;
                if retry_wait_seconds < 300 {
                    retry_wait_seconds += retry_wait_seconds
                };
            }
            Ok(settings_map) => break settings_map,
        }
    };
    println!("Settings successfully obtained.");
    println!("{:#?}", settings_map);

    async fn some_operation(message: &str, duration: Duration, receiver: watch::Receiver<()>) {
        loop {
            tokio::time::sleep(duration).await;

            let span = span!(Level::TRACE, "message span");
            let _enter = span.enter();
            println!("{}", message);
            event!(Level::INFO, message);

            if receiver.has_changed().unwrap_or(true) {
                break;
            };
        }
        println!("Task shutting down. ({})", message);

        // sender goes out of scope ...
    }

    let _op1 = tokio::spawn(some_operation(
        "Hello World!",
        Duration::from_secs(10),
        rx.clone(),
    ));

    let _op2 = tokio::spawn(some_operation(
        "hello world from a shorter loop!",
        Duration::from_secs(7),
        rx.clone(),
    ));

    match signal::ctrl_c().await {
        Ok(()) => {
            println!("Goodbye!");
        }
        Err(err) => {
            eprintln!("Unable to listen for shutdown signal: {}", err);
            // we also shut down in case of error
        }
    }
    // send shutdown signal to application and wait
    tx.send(())?;

    // // Wait for the tasks to finish.
    // //
    // // We drop our sender first because the recv() call otherwise
    // // sleeps forever.
    // drop(send);
    drop(rx);
    tx.closed().await;

    // When every sender has gone out of scope, the recv call
    // will return with an error. We ignore the error.
    // let _ = recv.recv().await;

    // Shutdown trace pipeline
    opentelemetry::global::shutdown_tracer_provider();

    println!("Tasks complete.");

    Ok(())
}

fn set_up_logging() -> Result<()> {
    // Install a new OpenTelemetry trace pipeline
    let tracer = opentelemetry_otlp::new_pipeline()
        .tracing()
        // with_env() gets OTEL endpoint from the env var OTEL_EXPORTER_OTLP_ENDPOINT
        // (if it is available)
        .with_exporter(opentelemetry_otlp::new_exporter().tonic().with_env())
        // config, service.name etc.
        .with_trace_config(opentelemetry::sdk::trace::config().with_resource(
            opentelemetry::sdk::Resource::new(vec![opentelemetry::KeyValue::new(
                "service.name",
                "hello-rust-backend",
            )]),
        ))
        .install_batch(opentelemetry::runtime::TokioCurrentThread)?;

    // Create a tracing layer with the configured tracer
    let opentelemetry = tracing_opentelemetry::layer().with_tracer(tracer);

    // The SubscriberExt and SubscriberInitExt traits are needed to extend the
    // Registry to accept `opentelemetry (the OpenTelemetryLayer type).
    tracing_subscriber::registry()
        .with(opentelemetry)
        // Continue logging to stdout as well
        .with(fmt::Layer::default())
        .try_init()?;

    Ok(())
}
