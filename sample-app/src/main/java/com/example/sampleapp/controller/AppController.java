package com.example.sampleapp.controller;

import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
public class AppController {

    @GetMapping(value = "/", produces = MediaType.TEXT_HTML_VALUE)
    public String index() {
        return """
                <!DOCTYPE html>
                <html lang="en">
                <head>
                    <meta charset="UTF-8">
                    <meta name="viewport" content="width=device-width, initial-scale=1.0">
                    <title>Sample App</title>
                </head>
                <body>
                    <h1>Sample Application</h1>
                    <p>CD Pipeline PoC with GitHub Actions, AWX, and OWASP ZAP.</p>
                    <nav>
                        <ul>
                            <li><a href="/health">Health Check</a></li>
                            <li><a href="/info">App Info</a></li>
                        </ul>
                    </nav>
                </body>
                </html>
                """;
    }

    @GetMapping(value = "/health", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, String> health() {
        return Map.of("status", "UP");
    }

    @GetMapping(value = "/info", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, String> info() {
        return Map.of(
                "app", "sample-app",
                "version", "0.0.1-SNAPSHOT",
                "description", "CD Pipeline PoC sample application"
        );
    }
}
