package com.redhat.repro;

import java.io.IOException;
import java.io.PrintWriter;
import java.net.InetAddress;
import __NS__.servlet.ServletException;
import __NS__.servlet.annotation.WebServlet;
import __NS__.servlet.http.HttpServlet;
import __NS__.servlet.http.HttpServletRequest;
import __NS__.servlet.http.HttpServletResponse;

/**
 * Non-clustered probe: proves the container is up, the deployment really answers, and
 * reports the runtime facts a reproduction needs to record.
 *
 * Used for cases that are not about session replication — deployment failures, TLS,
 * datasources, classloading, JVM behavior.
 *
 *   GET /info     runtime identity and JVM facts
 *   GET /health   plain 200 "OK" for readiness polling
 *   GET /info?prop=<name>   read one system property
 *   GET /info?env=<name>    read one environment variable
 */
@WebServlet(urlPatterns = {"/info", "/health"})
public class InfoServlet extends HttpServlet {

    private static final long serialVersionUID = 1L;

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp)
            throws ServletException, IOException {

        String node = System.getProperty("jboss.node.name", "unknown");
        resp.setHeader("X-Repro-Node", node);

        if (req.getRequestURI().endsWith("/health")) {
            resp.setContentType("text/plain; charset=UTF-8");
            try (PrintWriter out = resp.getWriter()) { out.println("OK"); }
            return;
        }

        String prop = req.getParameter("prop");
        String env = req.getParameter("env");
        String host;
        try { host = InetAddress.getLocalHost().getHostName(); }
        catch (Exception e) { host = "unknown"; }

        Runtime rt = Runtime.getRuntime();
        resp.setContentType("application/json; charset=UTF-8");
        try (PrintWriter out = resp.getWriter()) {
            out.println("{"
                + "\"node\":\"" + node + "\","
                + "\"host\":\"" + host + "\","
                + "\"contextPath\":\"" + req.getContextPath() + "\","
                + "\"scheme\":\"" + req.getScheme() + "\","
                + "\"secure\":" + req.isSecure() + ","
                + "\"protocol\":\"" + req.getProtocol() + "\","
                + "\"javaVersion\":\"" + System.getProperty("java.version") + "\","
                + "\"javaVendor\":\"" + System.getProperty("java.vendor") + "\","
                + "\"jvmName\":\"" + System.getProperty("java.vm.name") + "\","
                + "\"maxMemoryMB\":" + (rt.maxMemory() / 1048576) + ","
                + "\"freeMemoryMB\":" + (rt.freeMemory() / 1048576) + ","
                + "\"availableProcessors\":" + rt.availableProcessors() + ","
                + "\"property\":" + (prop == null ? "null"
                        : "{\"" + prop + "\":\"" + System.getProperty(prop) + "\"}") + ","
                + "\"env\":" + (env == null ? "null"
                        : "{\"" + env + "\":\"" + System.getenv(env) + "\"}")
                + "}");
        }
    }
}
