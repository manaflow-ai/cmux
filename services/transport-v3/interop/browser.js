import { createLibp2p } from 'libp2p'
import { webSockets } from '@libp2p/websockets'
import { circuitRelayTransport } from '@libp2p/circuit-relay-v2'
import { identify } from '@libp2p/identify'
import { noise } from '@chainsafe/libp2p-noise'
import { yamux } from '@chainsafe/libp2p-yamux'
import { multiaddr } from '@multiformats/multiaddr'

let node
window.prepare = async () => {
  node = await createLibp2p({
    transports: [webSockets(), circuitRelayTransport()],
    connectionEncrypters: [noise()], streamMuxers: [yamux()],
    // The test's Rust listeners bind exclusively to loopback.
    connectionGater: { denyDialMultiaddr: () => false },
    services: { identify: identify() }
  })
  return node.peerId.toString()
}

window.verify = async ({ address, grant }) => {
  async function request(token) {
    const stream = await node.dialProtocol(multiaddr(address), '/cmux/transport/3/probe', {
      signal: AbortSignal.timeout(15000), runOnLimitedConnection: true
    })
    stream.send(new TextEncoder().encode(JSON.stringify({ grant: token, message: 'browser to Rust' })))
    await stream.close()
    const decoder = new TextDecoder()
    let result = ''
    for await (const chunk of stream) result += decoder.decode(chunk.subarray(), { stream: true })
    return JSON.parse(result + decoder.decode())
  }
  try {
    return { allowed: await request(grant), denied: await request('invalid-grant') }
  } finally { await node.stop() }
}
