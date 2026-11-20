package org.bakasu.bakasu.domain.usecase

import org.bakasu.bakasu.data.update.ManagerUpdateRepository
import org.bakasu.bakasu.domain.model.ManagerUpdateChannel
import org.bakasu.bakasu.domain.model.ManagerUpdateInfo

class CheckManagerUpdateUseCase(
    private val repository: ManagerUpdateRepository,
) {
    // Fork build: no manager self-update check (upstream releases are signed with another key).
    @Suppress("UNUSED_PARAMETER")
    suspend operator fun invoke(channel: ManagerUpdateChannel): ManagerUpdateInfo? = null
}
