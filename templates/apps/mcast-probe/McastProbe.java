// McastProbe — can IP multicast actually carry a datagram on this host, on this interface?
//
// JGroups' udp stack needs exactly this and nothing more: join a group on a chosen interface,
// send a datagram, receive it back. Reading the kernel's MULTICAST flag is a different
// question with a different answer — a flagged interface behind a firewall still drops the
// packet — and the gap between the two is the gap between "the customer's configuration is
// wrong" and "the customer's network is". Measure it; do not infer it.
//
//   java McastProbe <bind-address> [group] [port]
//   prints RESULT=OK or RESULT=FAIL <reason>, exit 0 / 1
import java.net.DatagramPacket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.MulticastSocket;
import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;

public class McastProbe {
    public static void main(String[] args) {
        String bind  = args.length > 0 ? args[0] : "127.0.0.1";
        String group = args.length > 1 ? args[1] : "230.0.0.4";
        int    port  = args.length > 2 ? Integer.parseInt(args[2]) : 45688;

        MulticastSocket sock = null;
        try {
            InetAddress bindAddr  = InetAddress.getByName(bind);
            InetAddress groupAddr = InetAddress.getByName(group);
            NetworkInterface nif  = NetworkInterface.getByInetAddress(bindAddr);

            System.out.println("bind=" + bind + " group=" + group + " port=" + port);
            System.out.println("interface=" + (nif == null ? "UNRESOLVED" : nif.getName())
                    + " up=" + (nif != null && nif.isUp())
                    + " loopback=" + (nif != null && nif.isLoopback())
                    + " supportsMulticast=" + (nif == null ? "unknown" : nif.supportsMulticast()));

            // supportsMulticast() is printed above as context and is NOT acted on. An earlier
            // version of this probe returned FAIL here whenever the flag was absent. That was
            // an inference wearing a measurement's clothes, and it was wrong: Linux delivers
            // multicast between sockets on the same host locally, whatever the MULTICAST flag
            // on `lo` says. EAP formed a real 3-node cluster on the udp stack over 127.0.0.1
            // in the same run where this probe reported that no address on the host could
            // carry a datagram. Always attempt the round trip and let the datagram answer.

            sock = new MulticastSocket(port);
            sock.setSoTimeout(4000);
            sock.setTimeToLive(1);
            sock.setLoopbackMode(false);   // false DISABLES the disable, i.e. loop back to us
            if (nif != null) sock.setNetworkInterface(nif);
            sock.joinGroup(new InetSocketAddress(groupAddr, port), nif);

            byte[] payload = ("MCAST_PROBE_" + System.nanoTime()).getBytes(StandardCharsets.UTF_8);
            sock.send(new DatagramPacket(payload, payload.length, groupAddr, port));

            byte[] buf = new byte[512];
            DatagramPacket in = new DatagramPacket(buf, buf.length);
            sock.receive(in);   // SocketTimeoutException if the datagram never comes back
            System.out.println("received " + in.getLength() + " bytes from " + in.getAddress());
            System.out.println("RESULT=OK");
        } catch (Exception e) {
            System.out.println("RESULT=FAIL " + e.getClass().getSimpleName() + ": " + e.getMessage());
            System.exit(1);
        } finally {
            if (sock != null) sock.close();
        }
    }
}
