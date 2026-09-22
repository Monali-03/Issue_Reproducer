package com.redhat.repro;

import java.io.IOException;
import java.io.PrintWriter;
import java.util.Enumeration;
import __NS__.servlet.ServletException;
import __NS__.servlet.annotation.WebServlet;
import __NS__.servlet.http.HttpServlet;
import __NS__.servlet.http.HttpServletRequest;
import __NS__.servlet.http.HttpServletResponse;
import __NS__.servlet.http.HttpSession;

/**
 * Session replication probe.
 *
 * The whole point of this servlet is to make a failover verdict decidable from one HTTP
 * response: which node served it, which session it belongs to, and whether the replicated
 * state survived. Anything ambiguous here turns into an ambiguous verdict later.
 *
 *   GET  /session                  create-or-increment the counter
 *   GET  /session?set=k:v          store an attribute
 *   GET  /session?get=k            read an attribute back
 *   GET  /session?invalidate       invalidate the session
 *   GET  /session?size=N           store an N-kilobyte payload (replication sizing)
 *
 * Every response carries X-Repro-Node, so the caller always knows which backend answered
 * without having to infer it from the load balancer.
 */
@WebServlet(urlPatterns = {"/session"})
public class SessionServlet extends HttpServlet {

    private static final long serialVersionUID = 1L;
    private static final String COUNTER = "repro.counter";
    private static final String PAYLOAD = "repro.payload";

    /** Set by the container from -Djboss.node.name; identifies the serving backend. */
    private static String nodeName() {
        String n = System.getProperty("jboss.node.name");
        if (n == null) n = System.getProperty("node.name");
        if (n == null) n = System.getenv("NODE_NAME");
        return n == null ? "unknown" : n;
    }

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp)
            throws ServletException, IOException {

        final String node = nodeName();
        resp.setHeader("X-Repro-Node", node);
        resp.setContentType("application/json; charset=UTF-8");

        // invalidate: report the old id so the caller can prove the session really changed
        if (req.getParameter("invalidate") != null) {
            HttpSession existing = req.getSession(false);
            String oldId = existing == null ? "none" : existing.getId();
            if (existing != null) existing.invalidate();
            write(resp, "{\"node\":\"" + node + "\",\"action\":\"invalidate\","
                    + "\"oldSessionId\":\"" + oldId + "\"}");
            return;
        }

        // getSession(false) first: "was there already a session?" is the question a
        // failover test is actually asking, and getSession(true) would destroy the answer.
        HttpSession pre = req.getSession(false);
        boolean existedBefore = pre != null;
        HttpSession session = req.getSession(true);

        String set = req.getParameter("set");
        if (set != null && set.contains(":")) {
            int i = set.indexOf(':');
            session.setAttribute(set.substring(0, i), set.substring(i + 1));
        }

        String sizeParam = req.getParameter("size");
        if (sizeParam != null) {
            int kb = Integer.parseInt(sizeParam);
            StringBuilder sb = new StringBuilder(kb * 1024);
            for (int i = 0; i < kb * 1024; i++) sb.append('x');
            session.setAttribute(PAYLOAD, sb.toString());
        }

        Integer counter = (Integer) session.getAttribute(COUNTER);
        counter = (counter == null) ? 1 : counter + 1;
        session.setAttribute(COUNTER, counter);

        String getKey = req.getParameter("get");
        Object got = getKey == null ? null : session.getAttribute(getKey);

        StringBuilder attrs = new StringBuilder();
        Enumeration<String> names = session.getAttributeNames();
        while (names.hasMoreElements()) {
            String n = names.nextElement();
            if (attrs.length() > 0) attrs.append(',');
            attrs.append('"').append(n).append('"');
        }

        write(resp, "{"
                + "\"node\":\"" + node + "\","
                + "\"sessionId\":\"" + session.getId() + "\","
                + "\"counter\":" + counter + ","
                // isNew and existedBefore together distinguish "the session replicated"
                // from "the failover node quietly issued a brand-new one" — the exact
                // difference between NOT REPRODUCED and REPRODUCED for a session case.
                + "\"newSession\":" + session.isNew() + ","
                + "\"existedBeforeRequest\":" + existedBefore + ","
                + "\"creationTime\":" + session.getCreationTime() + ","
                + "\"lastAccessedTime\":" + session.getLastAccessedTime() + ","
                + "\"maxInactiveInterval\":" + session.getMaxInactiveInterval() + ","
                + "\"attributes\":[" + attrs + "],"
                + "\"requested\":" + (getKey == null ? "null"
                        : "{\"key\":\"" + getKey + "\",\"value\":"
                          + (got == null ? "null" : "\"" + got + "\"") + "}")
                + "}");
    }

    private void write(HttpServletResponse resp, String body) throws IOException {
        try (PrintWriter out = resp.getWriter()) {
            out.println(body);
        }
    }
}
