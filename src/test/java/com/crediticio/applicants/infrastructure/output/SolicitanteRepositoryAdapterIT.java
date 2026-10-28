package com.crediticio.applicants.infrastructure.output;

import com.crediticio.applicants.domain.DocumentoDuplicadoException;
import com.crediticio.applicants.domain.HistorialCrediticio;
import com.crediticio.applicants.domain.Solicitante;
import com.crediticio.support.ProteccionBaseIntegracion;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.data.jpa.test.autoconfigure.DataJpaTest;
import org.springframework.boot.jdbc.test.autoconfigure.AutoConfigureTestDatabase;
import org.springframework.context.annotation.Import;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.ContextConfiguration;

import java.math.BigDecimal;
import java.util.Optional;
import java.util.concurrent.ThreadLocalRandom;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Prueba de integración de persistencia contra PostgreSQL local real (no H2).
 *
 * Requiere PostgreSQL local y el perfil "it" (src/test/resources/application-it.properties).
 * No usa DB_URL: la URL se indica explícitamente con -D y {@link ProteccionBaseIntegracion}
 * aborta antes de crear el contexto (sin conectarse) si no apunta exactamente a la base
 * dedicada autorizada. DB_USERNAME y DB_PASSWORD se toman del entorno. Flyway aplicará las
 * migraciones pendientes contra esa base al iniciar el contexto.
 *
 * Al terminar en "IT" (no "Test"), Surefire no la ejecuta con `./mvnw test`.
 * Ejecución manual (requiere autorización expresa para usar la base dedicada):
 * ./mvnw.cmd -B test "-Dtest=SolicitanteRepositoryAdapterIT" "-Dspring.profiles.active=it"
 *     "-Dit.base-dedicada=motor_scoring_it"
 *     "-Dspring.datasource.url=jdbc:postgresql://localhost:5432/motor_scoring_it"
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@ActiveProfiles("it")
@ContextConfiguration(initializers = ProteccionBaseIntegracion.class)
@Import(SolicitanteRepositoryAdapter.class)
class SolicitanteRepositoryAdapterIT {

    @Autowired
    private SolicitanteRepositoryAdapter solicitanteRepositoryAdapter;

    @Autowired
    private SolicitanteJpaRepository solicitanteJpaRepository;

    @Test
    void elContextoCargaConFlywayYLaValidacionDeEsquemaDeHibernate() {
        assertThat(solicitanteRepositoryAdapter).isNotNull();
        assertThat(solicitanteJpaRepository).isNotNull();
    }

    @Test
    void debeGuardarElSolicitanteYGenerarIdYFechaDeRegistro() {
        Solicitante guardado = solicitanteRepositoryAdapter.guardar(solicitanteNuevo(documentoPrueba()));

        assertThat(guardado.getIdSolicitante()).isNotNull();
        assertThat(guardado.getFechaRegistro()).isNotNull();
    }

    @Test
    void debePersistirYPermitirLeerTodosLosCamposDelSolicitante() {
        String documento = documentoPrueba();
        Solicitante guardado = solicitanteRepositoryAdapter.guardar(solicitanteNuevo(documento));

        Optional<SolicitanteJpaEntity> leido = solicitanteJpaRepository.findById(guardado.getIdSolicitante());

        assertThat(leido).isPresent();
        SolicitanteJpaEntity entity = leido.get();
        assertThat(entity.getNombreCompleto()).isEqualTo("Ana María Pérez");
        assertThat(entity.getNumeroDocumento()).isEqualTo(documento);
        assertThat(entity.getIngresosMensuales()).isEqualByComparingTo(new BigDecimal("3000000"));
        assertThat(entity.getDeudasMensuales()).isEqualByComparingTo(new BigDecimal("500000"));
        assertThat(entity.getNumeroMoras()).isZero();
        assertThat(entity.getHistorialCrediticio()).isEqualTo(HistorialCrediticio.BUENO);
        assertThat(entity.getAntiguedadLaboral()).isEqualByComparingTo(new BigDecimal("2.5"));
        assertThat(entity.getFechaRegistro()).isNotNull();
    }

    @Test
    void debeLanzarDocumentoDuplicadoAlGuardarUnNumeroDeDocumentoYaExistente() {
        String documento = documentoPrueba();
        solicitanteRepositoryAdapter.guardar(solicitanteNuevo(documento));

        assertThatThrownBy(() -> solicitanteRepositoryAdapter.guardar(solicitanteNuevo(documento)))
                .isInstanceOf(DocumentoDuplicadoException.class);
    }

    @Test
    void debeExistePorNumeroDocumentoDetectarUnDocumentoYaRegistrado() {
        String documento = documentoPrueba();
        String documentoInexistente = documentoPrueba();
        solicitanteRepositoryAdapter.guardar(solicitanteNuevo(documento));

        assertThat(solicitanteRepositoryAdapter.existePorNumeroDocumento(documento)).isTrue();
        assertThat(solicitanteRepositoryAdapter.existePorNumeroDocumento(documentoInexistente)).isFalse();
    }

    @Test
    void debeBuscarPorNumeroDocumentoEncontrarElSolicitanteSinModificarloYRetornarVacioSiNoExiste() {
        String documento = documentoPrueba();
        String documentoInexistente = documentoPrueba();
        Solicitante guardado = solicitanteRepositoryAdapter.guardar(solicitanteNuevo(documento));

        Optional<Solicitante> encontrado = solicitanteRepositoryAdapter.buscarPorNumeroDocumento(documento);

        assertThat(encontrado).isPresent();
        assertThat(encontrado.get().getIdSolicitante()).isEqualTo(guardado.getIdSolicitante());
        assertThat(encontrado.get().getNombreCompleto()).isEqualTo(guardado.getNombreCompleto());
        assertThat(encontrado.get().getNumeroDocumento()).isEqualTo(documento);
        assertThat(encontrado.get().getIngresosMensuales()).isEqualByComparingTo(guardado.getIngresosMensuales());
        assertThat(encontrado.get().getDeudasMensuales()).isEqualByComparingTo(guardado.getDeudasMensuales());
        assertThat(encontrado.get().getNumeroMoras()).isEqualTo(guardado.getNumeroMoras());
        assertThat(encontrado.get().getHistorialCrediticio()).isEqualTo(guardado.getHistorialCrediticio());
        assertThat(encontrado.get().getAntiguedadLaboral()).isEqualByComparingTo(guardado.getAntiguedadLaboral());
        assertThat(encontrado.get().getFechaRegistro()).isEqualTo(guardado.getFechaRegistro());

        Optional<SolicitanteJpaEntity> persistidoTrasConsultar = solicitanteJpaRepository.findByNumeroDocumento(documento);
        assertThat(persistidoTrasConsultar).isPresent();
        assertThat(persistidoTrasConsultar.get().getIdSolicitante()).isEqualTo(guardado.getIdSolicitante());

        assertThat(solicitanteRepositoryAdapter.buscarPorNumeroDocumento(documentoInexistente)).isEmpty();
    }

    @Test
    void laBaseDeDatosDebeRechazarIngresosMensualesNegativosAunSaltandoLaValidacionDeDominio() {
        // El dominio (Solicitante) jamás permitiría este valor: se construye la entidad JPA
        // directamente para comprobar que la restricción de integridad definitiva vive en la
        // base de datos (CHECK ck_solicitante_ingresos_mensuales), no solo en la aplicación.
        SolicitanteJpaEntity entityConIngresosNegativos = new SolicitanteJpaEntity(
                "Ana María Pérez", documentoPrueba(), new BigDecimal("-1"), new BigDecimal("500000"), 0,
                HistorialCrediticio.BUENO, new BigDecimal("2.5"));

        assertThatThrownBy(() -> solicitanteJpaRepository.saveAndFlush(entityConIngresosNegativos))
                .isInstanceOf(DataIntegrityViolationException.class);
    }

    private Solicitante solicitanteNuevo(String numeroDocumento) {
        return Solicitante.nuevo(
                "Ana María Pérez",
                numeroDocumento,
                new BigDecimal("3000000"),
                new BigDecimal("500000"),
                0,
                HistorialCrediticio.BUENO,
                new BigDecimal("2.5"));
    }

    /** Usa documentos distintos entre ejecuciones para que repetir la IT no choque con filas antiguas. */
    private String documentoPrueba() {
        return Long.toString(ThreadLocalRandom.current().nextLong(100_000_000L, 1_000_000_000L));
    }
}
