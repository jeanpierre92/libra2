// Copyright (c) The Libra Core Contributors
// SPDX-License-Identifier: Apache-2.0

//! Processes that are directly spawned by shared mempool runtime initialization

use crate::{
    core_mempool::{CoreMempool, TimelineState},
    counters,
    network::{MempoolNetworkEvents, MempoolSyncMsg},
    shared_mempool::{
        tasks,
        types::{notify_subscribers, SharedMempool, SharedMempoolNotification},
    },
    CommitNotification, ConsensusRequest, SubmissionStatus,
};
use ::network::protocols::network::Event;
use anyhow::Result;
use bounded_executor::BoundedExecutor;
use channel::libra_channel;
use debug_interface::prelude::*;
use futures::{
    channel::{mpsc, oneshot},
    stream::{select_all, FuturesUnordered},
    StreamExt,
};
use libra_config::config::{PeerNetworkId, UpstreamNetworkId};
use libra_logger::prelude::*;
use libra_security_logger::{security_log, SecurityEvent};
use libra_types::{on_chain_config::OnChainConfigPayload, transaction::SignedTransaction};
use std::{
    ops::Deref,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{runtime::Handle, time::interval};
use vm_validator::vm_validator::TransactionValidation;

// JP CODE
use std::io::{prelude::*, BufWriter};
use std::{fs, thread, path::Path, fs::OpenOptions, time::SystemTime};
use futures::{channel::mpsc::{channel, Sender, Receiver}};

pub struct JPsenderStruct {
    pub to_file: i32,
    pub message: String,
}

/// Coordinator that handles inbound network events and outbound txn broadcasts.
pub(crate) async fn coordinator<V>(
    mut smp: SharedMempool<V>,
    executor: Handle,
    network_events: Vec<(UpstreamNetworkId, MempoolNetworkEvents)>,
    mut client_events: mpsc::Receiver<(
        SignedTransaction,
        oneshot::Sender<Result<SubmissionStatus>>,
    )>,
    mut consensus_requests: mpsc::Receiver<ConsensusRequest>,
    mut state_sync_requests: mpsc::Receiver<CommitNotification>,
    mut mempool_reconfig_events: libra_channel::Receiver<(), OnChainConfigPayload>,
) where
    V: TransactionValidation,
{
    let smp_events: Vec<_> = network_events
        .into_iter()
        .map(|(network_id, events)| events.map(move |e| (network_id, e)))
        .collect();
    let mut events = select_all(smp_events).fuse();
    let mempool = smp.mempool.clone();
    let peer_manager = smp.peer_manager.clone();
    let subscribers = &mut smp.subscribers.clone();
    let mut scheduled_broadcasts = FuturesUnordered::new();

    // Use a BoundedExecutor to restrict only `workers_available` concurrent
    // worker tasks that can process incoming transactions.
    let workers_available = smp.config.shared_mempool_max_concurrent_inbound_syncs;
    let bounded_executor = BoundedExecutor::new(workers_available, executor.clone());

    // JP CODE
    let (tx, mut rx): (Sender<JPsenderStruct>, Receiver<JPsenderStruct>) = channel(1024);
    fs::create_dir_all("/jp_metrics").unwrap();

    thread::spawn(move || {
        let paths = vec!["jp_mempool_process_incoming_transactions.csv",
                         "jp_ac_client_transaction.csv"];
                         
        let mut buf = vec![];

        for i in 0..paths.len() {
            let buf_handle = BufWriter::new(OpenOptions::new()
            .write(true)
            .read(true)
            .append(true)
            .create(true)
            .open(Path::new(&format!("jp_metrics/{}", paths.get(i).unwrap())))
            .expect("Cannot open file!"));
            buf.push(buf_handle);
        }

        loop {
            let received = rx.try_next();
            match received {
                Ok(raw_msg) => if let Some(mut msg) = raw_msg {
                    msg.message.push('\n');
                    match msg.to_file {
                        0 => buf[0].write_all(msg.message.as_bytes()).expect("Could not write to jp_mempool_process_incomming_tranactions.csv"),
                        1 => buf[1].write_all(msg.message.as_bytes()).expect("Could not write to jp_ac_client_transaction.csv"),
                        _ => panic!("shittt"),
                    }
                },
                Err(_) => {
                    for i in 0..buf.len() {
                        buf[i].flush().unwrap();
                    }
                    thread::sleep(std::time::Duration::from_millis(100));
                },
            }
        } 
    });

    let mut current_time;
    loop {
        current_time = SystemTime::now();
        ::futures::select! {
            (mut msg, callback) = client_events.select_next_some() => {
                trace_event!("mempool::client_event", {"txn", msg.sender(), msg.sequence_number()});
                bounded_executor
                .spawn(tasks::process_client_transaction_submission(
                    smp.clone(),
                    msg,
                    callback,
                    tx.clone(),
                    current_time,
                ))
                .await;
            },
            msg = consensus_requests.select_next_some() => {
                tasks::process_consensus_request(&mempool, msg).await;
            }
            msg = state_sync_requests.select_next_some() => {
                tokio::spawn(tasks::process_state_sync_request(mempool.clone(), msg));
            }
            config_update = mempool_reconfig_events.select_next_some() => {
                bounded_executor
                .spawn(tasks::process_config_update(config_update, smp.validator.clone()))
                .await;
            },
            (peer, backoff) = scheduled_broadcasts.select_next_some() => {
                tasks::execute_broadcast(peer, backoff, &mut smp, &mut scheduled_broadcasts, executor.clone());
            },
            (network_id, event) = events.select_next_some() => {
                match event {
                    Ok(network_event) => {
                        match network_event {
                            Event::NewPeer(peer_id) => {
                                counters::SHARED_MEMPOOL_EVENTS
                                    .with_label_values(&["new_peer".to_string().deref()])
                                    .inc();
                                let peer = PeerNetworkId(network_id, peer_id);
                                let is_new_peer = peer_manager.add_peer(peer);
                                notify_subscribers(SharedMempoolNotification::PeerStateChange, &subscribers);
                                if is_new_peer && peer_manager.is_upstream_peer(peer) {
                                    tasks::execute_broadcast(peer, false, &mut smp, &mut scheduled_broadcasts, executor.clone());
                                }
                            }
                            Event::LostPeer(peer_id) => {
                                counters::SHARED_MEMPOOL_EVENTS
                                    .with_label_values(&["lost_peer".to_string().deref()])
                                    .inc();
                                peer_manager.disable_peer(PeerNetworkId(network_id, peer_id));
                                notify_subscribers(SharedMempoolNotification::PeerStateChange, &subscribers);
                            }
                            Event::Message((peer_id, msg)) => {
                                counters::SHARED_MEMPOOL_EVENTS
                                    .with_label_values(&["message".to_string().deref()])
                                    .inc();
                                match msg {
                                    MempoolSyncMsg::BroadcastTransactionsRequest{request_id, transactions} => {
                                        counters::SHARED_MEMPOOL_TRANSACTIONS_PROCESSED
                                            .with_label_values(&["received".to_string().deref(), peer_id.to_string().deref()])
                                            .inc_by(transactions.len() as i64);
                                        let smp_clone = smp.clone();
                                        let peer = PeerNetworkId(network_id, peer_id);
                                        let timeline_state = match peer_manager
                                            .is_upstream_peer(peer)
                                        {
                                            true => TimelineState::NonQualified,
                                            false => TimelineState::NotReady,
                                        };
                                        bounded_executor
                                            .spawn(tasks::process_transaction_broadcast(
                                                smp_clone,
                                                transactions,
                                                request_id,
                                                timeline_state,
                                                peer,
                                                tx.clone()
                                            ))
                                            .await;
                                    }
                                    MempoolSyncMsg::BroadcastTransactionsResponse{request_id, retry_txns, backoff} => {
                                        let peer = PeerNetworkId(network_id, peer_id);
                                        peer_manager.process_broadcast_ack(PeerNetworkId(network_id, peer_id), request_id, retry_txns, backoff);
                                        notify_subscribers(SharedMempoolNotification::ACK, &smp.subscribers);
                                    }
                                };
                            }
                            _ => {
                                security_log(SecurityEvent::InvalidNetworkEventMP)
                                    .error("UnexpectedNetworkEvent")
                                    .data(&network_event)
                                    .log();
                                debug_assert!(false, "Unexpected network event");
                            }
                        }
                    },
                    Err(e) => {
                        security_log(SecurityEvent::InvalidNetworkEventMP)
                            .error(&e)
                            .log();
                    }
                };
            },
            complete => break,
        }
    }
    crit!("[shared mempool] inbound_network_task terminated");
}

/// GC all expired transactions by SystemTTL
pub(crate) async fn gc_coordinator(mempool: Arc<Mutex<CoreMempool>>, gc_interval_ms: u64) {
    let mut interval = interval(Duration::from_millis(gc_interval_ms));
    while let Some(_interval) = interval.next().await {
        mempool
            .lock()
            .expect("[shared mempool] failed to acquire mempool lock")
            .gc();
    }

    crit!("SharedMempool gc_task terminated");
}
