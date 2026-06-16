use std::path::PathBuf;

use tracing::Subscriber;
use tracing_subscriber::fmt::MakeWriter;
use tracing_subscriber::{EnvFilter, prelude::*};

/// Sets up a tracing subscriber.
pub fn get_subscriber<Sink>(
    name: String,
    env_filter: String,
    sink: Sink,
    log_file: Option<PathBuf>,
) -> impl Subscriber + Send + Sync
where
    Sink: for<'a> MakeWriter<'a> + Send + Sync + 'static,
{
    let filter_layer =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(env_filter.clone()));

    let file = log_file.map(|path| {
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .unwrap_or_else(|e| panic!("Failed to open log file '{}': {e}", path.display()))
    });

    // TODO: Consider rewriting the mutually-exclusive 'bunyan' feature to make two additive
    // features that are given separate sinks and let the user configure as they desire.

    // INFO: Tracing subscriber plain text log
    #[cfg(not(feature = "bunyan"))]
    {
        use tracing_subscriber::fmt::{self, format::FmtSpan};

        let fmt_layer = fmt::layer()
            .compact()
            .with_target(true)
            .with_line_number(true)
            .with_span_events(FmtSpan::NONE)
            .with_writer(sink)
            .boxed();

        let file_layer = file.map(|file| {
            fmt::layer()
                .compact()
                .with_target(true)
                .with_line_number(true)
                .with_span_events(FmtSpan::NONE)
                .with_ansi(false)
                .with_writer(file)
                .with_filter(filter_layer.clone())
                .boxed()
        });

        tracing_subscriber::registry()
            .with(fmt_layer.with_filter(filter_layer))
            .with(file_layer)
    }

    // INFO: Bunyan
    #[cfg(feature = "bunyan")]
    {
        use tracing_bunyan_formatter::{BunyanFormattingLayer, JsonStorageLayer};
        use tracing_subscriber::Registry;

        let file_layer = file.map(|file| {
            BunyanFormattingLayer::new(name.clone(), file).with_filter(filter_layer.clone())
        });

        Registry::default()
            .with(JsonStorageLayer)
            .with(BunyanFormattingLayer::new(name.clone(), sink).with_filter(filter_layer))
            .with(file_layer)
    }
}

/// Sets the global default subscriber. Should only be called once.
pub fn init_subscriber<Sink>(
    name: String,
    env_filter: String,
    sink: Sink,
    log_file: Option<PathBuf>,
) where
    Sink: for<'a> MakeWriter<'a> + Send + Sync + 'static,
{
    if tracing::dispatcher::has_been_set() {
        return;
    }

    // DEBUG level by default if not compiled with --release, or INFO if so.
    // Override with RUST_LOG
    let env_filter = if env_filter.to_lowercase() != "trace" && cfg!(debug_assertions) {
        "DEBUG".to_owned()
    } else {
        env_filter
    };

    let subscriber = get_subscriber(name, env_filter, sink, log_file.clone());

    let _ = tracing::subscriber::set_global_default(subscriber)
        .map_err(|_err| eprintln!("Unable to set global default subscriber"));

    tracing::debug!("Tracing subscriber setup complete");
    if let Some(path) = log_file {
        tracing::info!("Logging to {}", path.display());
    }
}

#[cfg(feature = "tokio")]
pub mod tokio {
    use tokio::task::JoinHandle;
    use tracing::instrument;
    #[instrument(skip_all)]
    pub fn spawn_blocking_with_tracing<F, R>(f: F) -> JoinHandle<R>
    where
        F: FnOnce() -> R + Send + 'static,
        R: Send + 'static,
    {
        let current_span = tracing::Span::current();
        tokio::task::spawn_blocking(move || current_span.in_scope(f))
    }
}

#[cfg(feature = "axum")]
pub mod axum {
    use axum::Router;
    use tower::ServiceBuilder;
    use tower_http::ServiceBuilderExt;
    use tower_http::request_id::MakeRequestUuid;
    use tower_http::trace::{DefaultMakeSpan, DefaultOnResponse, TraceLayer};
    use tracing::Level;
    pub trait RouterExt {
        fn add_axum_tracing_layer(self) -> Self;
    }

    impl<S> RouterExt for Router<S>
    where
        // B: HttpBody + Send + 'static,
        S: Clone + Send + Sync + 'static,
    {
        fn add_axum_tracing_layer(self) -> Self {
            self.layer(
                ServiceBuilder::new()
                    .set_x_request_id(MakeRequestUuid)
                    .layer(
                        TraceLayer::new_for_http()
                            .make_span_with(
                                DefaultMakeSpan::new()
                                    .include_headers(true)
                                    .level(Level::INFO),
                            )
                            .on_response(DefaultOnResponse::new().include_headers(true)),
                    )
                    .propagate_x_request_id(),
            )
        }
    }
}
