use super::types::{
    ActiveWindow, ActiveWindowGeneric, CompositorCommand, CompositorEvent, CompositorMonitor,
    CompositorService, CompositorState, CompositorWorkspace,
};
use std::{
    collections::HashMap, env, os::unix::net::UnixStream as StdUnixStream, path::PathBuf,
};
use crate::services::ServiceEvent;
use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
    sync::broadcast,
};

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum Request {
    Action(Action),
    EventStream,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum Action {
    FocusWorkspace(u32),
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "snake_case")]
enum Reply {
    Ok,
    Err(String),
}

#[derive(Deserialize, Debug, Clone, Default)]
struct Window {
    workspace: Option<u32>,
    app_id: Option<String>,
    title: Option<String>,
    focused: bool,
}

#[derive(Deserialize, Debug, Clone)]
struct Workspace {
    id: u32,
    output: Option<String>,
    focused: bool,
    populated: bool,
}

#[derive(Deserialize, Debug, Clone)]
struct Output {
    name: String,
    workspace: Option<u32>,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "snake_case")]
enum Event {
    WorkspacesChanged(Vec<Workspace>),
    WindowsChanged(Vec<Window>),
    OutputsChanged(Vec<Output>),
    #[serde(other)]
    Unknown,
}

#[derive(Default)]
struct State {
    workspaces: Vec<Workspace>,
    windows: Vec<Window>,
    outputs: Vec<Output>,
}

fn socket_path() -> Option<PathBuf> {
    if let Some(path) = env::var_os("DELTA_SOCKET") {
        return Some(PathBuf::from(path));
    }

    let dir = env::var_os("XDG_RUNTIME_DIR")?;
    let display = env::var("WAYLAND_DISPLAY").ok()?;

    Some(PathBuf::from(dir).join(format!("delta-{display}.sock")))
}

pub fn is_available() -> bool {
    let path = socket_path();
    eprintln!("delta backend: socket_path = {path:?}");
    let ok = path.is_some_and(|p| p.exists());
    eprintln!("delta backend: is_available = {ok}");
    ok
}

async fn connect() -> Result<UnixStream> {
    let path = socket_path()
        .ok_or_else(|| anyhow!("cannot locate delta's socket; is delta running?"))?;

    let stream = StdUnixStream::connect(&path)
        .with_context(|| format!("connecting to {}", path.display()))?;
    stream.set_nonblocking(true)?;

    UnixStream::from_std(stream).context("converting the delta socket")
}

pub async fn execute_command(cmd: CompositorCommand) -> Result<()> {
    let action = match cmd {
        CompositorCommand::FocusWorkspace(id) => u32::try_from(id)
            .map(Action::FocusWorkspace)
            .map_err(|_| anyhow!("workspace {id} is out of range for delta"))?,

        other => return Err(anyhow!("{other:?} is not supported on delta")),
    };

    let mut stream = connect().await?;

    let mut json = serde_json::to_string(&Request::Action(action))?;
    json.push('\n');
    stream.write_all(json.as_bytes()).await?;
    stream.flush().await?;

    let mut reader = BufReader::new(&mut stream);
    let mut line = String::new();
    reader.read_line(&mut line).await?;
    eprintln!("delta backend: handshake = {line:?}");

    if let Reply::Err(msg) = serde_json::from_str::<Reply>(&line).context("parsing handshake")? {
        return Err(anyhow!("delta refused the event stream: {msg}"));
    }

    eprintln!("delta backend: handshake ok, streaming");

    match serde_json::from_str::<Reply>(&line)? {
        Reply::Ok => Ok(()),
        Reply::Err(msg) => Err(anyhow!("delta returned an error: {msg}")),
    }
}

pub async fn run_listener(tx: &broadcast::Sender<ServiceEvent<CompositorService>>) -> Result<()> {
    eprintln!("delta backend: connecting");
    let mut stream = connect().await?;

    let mut json = serde_json::to_string(&Request::EventStream)?;
    json.push('\n');
    stream.write_all(json.as_bytes()).await?;
    stream.flush().await?;

    let mut reader = BufReader::new(stream);

    let mut line = String::new();
    reader.read_line(&mut line).await?;
    if let Reply::Err(msg) = serde_json::from_str::<Reply>(&line).context("parsing handshake")? {
        return Err(anyhow!("delta refused the event stream: {msg}"));
    }

    let _ = reader.get_mut().shutdown().await;

    let mut state = State::default();

    loop {
        line.clear();
        if reader.read_line(&mut line).await? == 0 {
            break;
        }

        let event: Event = match serde_json::from_str(&line) {
            Ok(event) => event,
            Err(e) => {
                eprintln!("delta backend: unparseable event: {e} in {line}");
                continue;
            }
        };

        eprintln!("delta backend: applied {event:?}");

        match event {
            Event::WorkspacesChanged(workspaces) => state.workspaces = workspaces,
            Event::WindowsChanged(windows) => state.windows = windows,
            Event::OutputsChanged(outputs) => state.outputs = outputs,
            Event::Unknown => continue,
        }

        let _ = tx.send(ServiceEvent::Update(CompositorEvent::StateChanged(
            Box::new(map_state(&state)),
        )));
    }

    Ok(())
}

fn map_state(state: &State) -> CompositorState {
    let output_index: HashMap<&str, i128> = state
        .outputs
        .iter()
        .enumerate()
        .map(|(i, o)| (o.name.as_str(), i as i128))
        .collect();

    let collect_classes = super::should_collect_window_classes();

    let mut classes: HashMap<u32, Vec<String>> = HashMap::new();
    let mut counts: HashMap<u32, u16> = HashMap::new();

    for window in &state.windows {
        let Some(id) = window.workspace else { continue };

        *counts.entry(id).or_default() += 1;

        if collect_classes && let Some(app_id) = &window.app_id {
            classes.entry(id).or_default().push(app_id.clone());
        }
    }

    let workspaces = state
        .workspaces
        .iter()
        .map(|ws| {
            let monitor = ws.output.clone().unwrap_or_default();
            CompositorWorkspace {
                id: ws.id as i32,
                index: ws.id as i32,
                name: ws.id.to_string(),
                monitor_id: output_index.get(monitor.as_str()).copied(),
                monitor,
                windows: counts.get(&ws.id).copied().unwrap_or(if ws.populated {
                    1
                } else {
                    0
                }),
                is_special: false,
                has_urgent: false,
                window_classes: classes.remove(&ws.id).unwrap_or_default(),
            }
        })
        .collect();

    let monitors = state
        .outputs
        .iter()
        .enumerate()
        .map(|(i, o)| CompositorMonitor {
            id: i as i128,
            name: o.name.clone(),
            active_workspace_id: o.workspace.map_or(-1, |id| id as i32),
            special_workspace_id: -1,
        })
        .collect();

    let active_workspace_ids = state
        .workspaces
        .iter()
        .filter(|ws| ws.focused)
        .map(|ws| ws.id as i32)
        .collect();

    let active_window = state.windows.iter().find(|w| w.focused).map(|w| {
        ActiveWindow::Generic(ActiveWindowGeneric {
            title: w.title.clone().unwrap_or_default(),
            class: w.app_id.clone().unwrap_or_default(),
        })
    });

    CompositorState {
        workspaces,
        monitors,
        active_workspace_ids,
        active_window,
        keyboard_layout: String::new(),
        submap: None,
    }
}
