package com.crediticio.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpMethod;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.util.Assert;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.List;

/**
 * Protege exclusivamente el endpoint de scrape de Prometheus con una cuenta técnica HTTP Basic, independiente de
 * los JWT de usuario (mismo diseño que evaluation-query-api, docs/operacion/metricas-prometheus.md).
 *
 * Solo existe con scoring.metrics.enabled=true (SCORING_METRICS_ENABLED). Sin habilitarla, la cadena JWT
 * principal (SecurityConfig) deniega /actuator/prometheus con su regla anyRequest().denyAll().
 *
 * La cuenta técnica se valida con un AuthenticationManager propio de esta cadena: no se publica ningún bean
 * UserDetailsService ni PasswordEncoder que pudiera alterar la autenticación del resto de la aplicación.
 */
@Configuration
@ConditionalOnProperty(prefix = "scoring.metrics", name = "enabled", havingValue = "true")
public class MetricsSecurityConfiguration {

    static final String ROL_PROMETHEUS = "ROLE_PROMETHEUS";

    @Bean
    @Order(1)
    SecurityFilterChain metricsSecurityFilterChain(
            HttpSecurity http,
            @Value("${scoring.metrics.username:}") String usuario,
            @Value("${scoring.metrics.password:}") String clave) throws Exception {
        Assert.hasText(usuario, "Debe configurarse SCORING_METRICS_USERNAME cuando las métricas están habilitadas");
        Assert.hasText(clave, "Debe configurarse SCORING_METRICS_PASSWORD cuando las métricas están habilitadas");

        http
                .securityMatcher("/actuator/prometheus")
                // Solo lectura con autenticación Basic explícita, sin cookies ni sesiones: CSRF no aplica.
                .csrf(AbstractHttpConfigurer::disable)
                .sessionManagement(sesion -> sesion.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authenticationManager(cuentaTecnica(usuario, clave))
                .authorizeHttpRequests(autorizacion -> autorizacion
                        .requestMatchers(HttpMethod.GET, "/actuator/prometheus").hasAuthority(ROL_PROMETHEUS)
                        .anyRequest().denyAll())
                .httpBasic(Customizer.withDefaults());

        return http.build();
    }

    private static AuthenticationManager cuentaTecnica(String usuarioEsperado, String claveEsperada) {
        byte[] usuarioBytes = usuarioEsperado.getBytes(StandardCharsets.UTF_8);
        byte[] claveBytes = claveEsperada.getBytes(StandardCharsets.UTF_8);
        return autenticacion -> {
            String usuario = autenticacion.getName();
            Object credenciales = autenticacion.getCredentials();
            String clave = credenciales == null ? "" : credenciales.toString();
            // Comparación en tiempo constante; se evalúan ambas para no revelar cuál falló.
            boolean usuarioValido = MessageDigest.isEqual(usuarioBytes, usuario.getBytes(StandardCharsets.UTF_8));
            boolean claveValida = MessageDigest.isEqual(claveBytes, clave.getBytes(StandardCharsets.UTF_8));
            if (usuarioValido && claveValida) {
                return UsernamePasswordAuthenticationToken.authenticated(
                        usuario, null, List.of(new SimpleGrantedAuthority(ROL_PROMETHEUS)));
            }
            throw new BadCredentialsException("Credenciales de métricas inválidas");
        };
    }
}
