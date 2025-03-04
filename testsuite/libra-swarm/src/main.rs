// Copyright (c) The Libra Core Contributors
// SPDX-License-Identifier: Apache-2.0

#![forbid(unsafe_code)]

use libra_config::config::NodeConfig;
use libra_management::config_builder::FullnodeType;
use libra_swarm::{client, swarm::LibraSwarm};
use libra_temppath::TempPath;
use std::path::Path;
use structopt::StructOpt;

use std::fs::File;
use std::io::prelude::*;

#[derive(Debug, StructOpt)]
#[structopt(about = "Libra swarm to start local nodes")]
struct Args {
    /// Number of nodes to start (1 by default)
    #[structopt(short = "n", long, default_value = "1")]
    pub num_nodes: usize,
    /// Enable logging, by default spawned nodes will not perform logging
    #[structopt(short = "l", long)]
    pub enable_logging: bool,
    /// Start client
    #[structopt(short = "s", long)]
    pub start_client: bool,
    /// Directory used by launch_swarm to output LibraNodes' config files, logs, libradb, etc,
    /// such that user can still inspect them after exit.
    /// If unspecified, a temporary dir will be used and auto deleted.
    #[structopt(short = "c", long)]
    pub config_dir: Option<String>,
    /// If greater than 0, starts a full node swarm connected to the first node in the validator
    /// swarm.
    #[structopt(short = "f", long, default_value = "0")]
    pub num_full_nodes: usize,
}

fn main() {
    let args = Args::from_args();
    let num_nodes = args.num_nodes;
    let num_full_nodes = args.num_full_nodes;

    libra_logger::Logger::new().init();

    let mut validator_swarm =
        LibraSwarm::configure_validator_swarm(num_nodes, args.config_dir.clone(), None)
            .expect("Failed to configure validator swarm");

    let mut full_node_swarm = if num_full_nodes > 0 {
        Some(
            LibraSwarm::configure_fn_swarm(
                None, /* config dir */
                None,
                &validator_swarm.config,
                FullnodeType::ValidatorFullnode,
            )
            .expect("Failed to configure full node swarm"),
        )
    } else {
        None
    };
    validator_swarm
        .launch_attempt(!args.enable_logging)
        .expect("Failed to launch validator swarm");
    if let Some(ref mut swarm) = full_node_swarm {
        swarm
            .launch_attempt(!args.enable_logging)
            .expect("Failed to launch full node swarm");
    }

    let faucet_key_file_path = &validator_swarm.config.faucet_key_path;
    let validator_config = NodeConfig::load(&validator_swarm.config.config_files[0]).unwrap();
    let waypoint = validator_config.base.waypoint.waypoint();

    println!("To run the Libra CLI client in a separate process and connect to the validator nodes you just spawned, use this command:");

    println!(
        "\tcargo run --bin cli -- -u {} -m {:?} --waypoint {}",
        format!("http://localhost:{}", validator_config.rpc.address.port()),
        faucet_key_file_path,
        waypoint,
    );

    let ports = validator_swarm.config.config_files.iter().map(|config| {
        let validator_config = NodeConfig::load(config).unwrap();
        let port = validator_config.rpc.address.port();
        let debug_interface_port = validator_config
            .debug_interface
            .admission_control_node_debug_port;
        (port, debug_interface_port)
    });

    let node_address_list = ports
        .clone()
        .map(|port| format!("localhost:{}", port.0))
        .collect::<Vec<String>>()
        .join(",");

    println!("To run transaction generator run:");
    println!(
        "\tcargo run -p cluster-test -- --mint-file {:?} --swarm --peers {:?} --emit-tx --workers-per-ac 1",
        faucet_key_file_path, node_address_list,
    );

    let node_address_list = ports
        .map(|port| format!("localhost:{}:{}", port.0, port.1))
        .collect::<Vec<String>>()
        .join(",");

    println!("To run health check:");
    println!(
        "\tcargo run -p cluster-test -- --mint-file {:?} --swarm --peers {:?} --health-check --duration 30",
        faucet_key_file_path, node_address_list,
    );

    if let Some(ref swarm) = full_node_swarm {
        let full_node_config = NodeConfig::load(&swarm.config.config_files[0]).unwrap();
        println!("To connect to the full nodes you just spawned, use this command:");
        println!(
            "\tcargo run --bin cli -- -u {} -m {:?} --waypoint {}",
            format!("http://localhost:{}", full_node_config.rpc.address.port()),
            faucet_key_file_path,
            waypoint,
        );
    }

    if args.start_client {
        let tmp_mnemonic_file = TempPath::new();
        tmp_mnemonic_file.create_as_file().unwrap();

        let port = validator_swarm.get_client_port(0);
        let client = client::InteractiveClient::new_with_inherit_io(
            port,
            Path::new(&faucet_key_file_path),
            &tmp_mnemonic_file.path(),
            waypoint,
        );
        println!("Loading client...");
        let _output = client.output().expect("Failed to wait on child");
        println!("Exit client.");
    } else {
        // Explicitly capture CTRL-C to drop LibraSwarm.
        let (tx, rx) = std::sync::mpsc::channel();
        ctrlc::set_handler(move || {
            tx.send(())
                .expect("failed to send unit when handling CTRL-C");
        })
        .expect("failed to set CTRL-C handler");
        println!("CTRL-C to exit.");
        rx.recv()
            .expect("failed to receive unit when handling CTRL-C");
    }

    if let Some(dir) = &args.config_dir {
        println!("Please manually cleanup {:?} after inspection", dir);
    }

    println!("Exit libra-swarm.");
}
