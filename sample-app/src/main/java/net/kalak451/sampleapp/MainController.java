package net.kalak451.sampleapp;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.util.UriComponentsBuilder;
import reactor.core.publisher.Mono;
import reactor.core.scheduler.Schedulers;

import javax.sql.DataSource;
import java.net.URI;

@RestController
public class MainController {

    private final DataSource dataSource;


    public MainController(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @GetMapping(path = "/")
    public Mono<String> helloWorld() {

        return Mono.fromCallable(() -> new JdbcTemplate(dataSource))
                .subscribeOn(Schedulers.boundedElastic())
                .map(template -> template.queryForList("select * from sample_app.widgets"))
                .map(result -> String.format("Result Count: %s", result.size()));
    }

    @GetMapping(path="/add")
    public Mono<ResponseEntity<Void>> add() {
        return Mono.fromCallable(() -> new JdbcTemplate(dataSource))
                .subscribeOn(Schedulers.boundedElastic())
                .map(template -> template.update("insert into sample_app.widgets (operation) values ('add')"))
                .map(result -> ResponseEntity.status(HttpStatus.FOUND)
                        .location(UriComponentsBuilder.fromUriString("/").build().toUri())
                        .build()
                );
    }
}
