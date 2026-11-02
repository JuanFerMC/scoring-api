package com.crediticio.scoring.infrastructure.output;

import com.crediticio.scoring.domain.OperadorScoring;
import com.crediticio.scoring.domain.ReglaScoring;
import com.crediticio.scoring.domain.ReglaScoringDuplicadaException;
import com.crediticio.scoring.domain.TipoVariable;
import jakarta.persistence.EntityManager;
import org.hibernate.exception.ConstraintViolationException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.test.util.ReflectionTestUtils;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ReglaScoringRepositoryAdapterTest {

    private ReglaScoringJpaRepository repository;
    private EntityManager entityManager;
    private ReglaScoringRepositoryAdapter adapter;

    @BeforeEach
    void setUp() {
        repository = mock(ReglaScoringJpaRepository.class);
        entityManager = mock(EntityManager.class);
        adapter = new ReglaScoringRepositoryAdapter(repository);
        ReflectionTestUtils.setField(adapter, "entityManager", entityManager);
        when(repository.save(any(ReglaScoringJpaEntity.class))).thenReturn(
                new ReglaScoringJpaEntity(1L, ">", "100", 10,
                        com.crediticio.scoring.domain.EstadoReglaScoring.ACTIVA));
    }

    @Test
    void debeTraducirViolacionDeIntegridadDeSpringAExcepcionDeDominio() {
        doThrow(new DataIntegrityViolationException("duplicate"))
                .when(entityManager).flush();

        assertThatThrownBy(() -> adapter.guardar(reglaNueva()))
                .isInstanceOf(ReglaScoringDuplicadaException.class);
    }

    @Test
    void debeTraducirViolacionDeRestriccionDeHibernateAExcepcionDeDominio() {
        doThrow(new ConstraintViolationException("duplicate", null, "uq_regla_scoring_condicion"))
                .when(entityManager).flush();

        assertThatThrownBy(() -> adapter.guardar(reglaNueva()))
                .isInstanceOf(ReglaScoringDuplicadaException.class);
    }

    private static ReglaScoring reglaNueva() {
        return ReglaScoring.nueva(1L, OperadorScoring.MAYOR, "100", 10, TipoVariable.NUMERICO, false);
    }
}
