package com.crediticio.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.security.autoconfigure.actuate.web.servlet.EndpointRequest;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.core.userdetails.User;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.provisioning.InMemoryUserDetailsManager;
import org.springframework.security.web.SecurityFilterChain;

@Configuration(proxyBeanMethods = false)
public class ActuatorSecurityConfig {

    @Bean
    @Order(1)
    public SecurityFilterChain prometheusSecurityFilterChain(HttpSecurity http) throws Exception {
        http
                .securityMatcher(EndpointRequest.to("prometheus"))
                .csrf(AbstractHttpConfigurer::disable)
                .sessionManagement(sesion -> sesion
                        .sessionCreationPolicy(
                                org.springframework.security.config.http.SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(autorizacion -> autorizacion
                        .anyRequest().hasRole("PROMETHEUS"))
                .httpBasic(Customizer.withDefaults());

        return http.build();
    }

    @Bean
    public PasswordEncoder monitoringPasswordEncoder() {
        return new BCryptPasswordEncoder(12);
    }

    @Bean
    public UserDetailsService monitoringUserDetailsService(
            @Value("${SCORING_PROMETHEUS_USERNAME}") String usuario,
            @Value("${SCORING_PROMETHEUS_PASSWORD}") String clave,
            PasswordEncoder monitoringPasswordEncoder) {

        if (usuario.isBlank()) {
            throw new IllegalStateException(
                    "SCORING_PROMETHEUS_USERNAME no puede estar vacio");
        }

        if (clave.length() < 24) {
            throw new IllegalStateException(
                    "SCORING_PROMETHEUS_PASSWORD debe tener al menos 24 caracteres");
        }

        return new InMemoryUserDetailsManager(
                User.withUsername(usuario)
                        .password(monitoringPasswordEncoder.encode(clave))
                        .roles("PROMETHEUS")
                        .build());
    }
}
