!--------------------------------------------------------------------------!
! The Phantom Smoothed Particle Hydrodynamics code, by Daniel Price et al. !
! Copyright (c) 2007-2021 The Authors (see AUTHORS)                        !
! See LICENCE file for usage and distribution conditions                   !
! http://phantomsph.bitbucket.io/                                          !
!--------------------------------------------------------------------------!
module analysis

   use physcon,        only: mass_proton_cgs, kboltz, atomic_mass_unit
   use cooling
   use cooling_functions
   use cooling_solver
   use dust_formation, only: init_muGamma, set_abundances, kappa_gas, &
                             calc_kappa_bowen, chemical_equilibrium_light, mass_per_H
   use dim,            only:nElements

   implicit none

   character(len=20), parameter, public :: analysistype = 'cooling'
   public :: do_analysis
   private
   integer                              :: analysis_to_perform
   real, parameter :: patm = 1.013250d6
   real    :: Aw(nElements) = [1.0079, 4.0026, 12.011, 15.9994, 14.0067, 20.17, 28.0855, 32.06, 55.847, 47.867]
   real    :: eps(nElements) = [1.d0, 1.04d-1, 0.0,  6.d-4, 2.52d-4, 1.17d-4, 3.58d-5, 1.85d-5, 3.24d-5, 8.6d-8]


contains

subroutine do_analysis(dumpfile,num,xyzh,vxyzu,particlemass,npart,time,iunit)

 use prompting,  only:prompt

 character(len=*), intent(in) :: dumpfile
 integer,          intent(in) :: num,npart,iunit
 real(kind=8),     intent(in) :: xyzh(:,:),vxyzu(:,:)
 real(kind=8),     intent(in) :: particlemass,time


 print "(29(a,/))", &
      ' 1) get rate', &
      ' 2) generate table', &
      ' 3) test integration'

 analysis_to_perform = 1

 call prompt('Choose analysis type ',analysis_to_perform,1,3)

 !analysis
 select case(analysis_to_perform)
 case(1) !test rate
    call get_rate()
 case(2)
    call generate_grid()
 case(3)
    call test_solvers
 end select
end subroutine do_analysis


subroutine test_solvers

  use physcon,  only:Rg
  use units,    only:unit_ergg,unit_density,utime
  use options,  only:icooling

  integer, parameter :: ndt = 20
  real :: tstart,tlast,dtstep,dti(ndt),tcool
  real :: rho, T_gas, rho_gas, pH, pH2   !rho in code units
  real :: mu, gamma
  real :: K2, kappa       !cgs
  real :: Q, dlnQ_dlnT
  real :: u,ui,xi,yi,zi,dudt,T_on_u,T,Tout,dt

  integer :: i,imethod,ierr

  Townsend_test = .true.

!set timesteps
  tstart = 0.1
  tlast = 10.
  dtstep = log10(tlast/tstart)/(ndt-1)
  do i = 1,ndt
     dti(i) = log10(tstart)+(i-1)*dtstep
  enddo
  dti = 10.**dti

  !default cooling prescriptionHI
  excitation_HI  = 1
  icooling = 1
  icool_method = 1 !0=implicit, 1=explicit, 2=exact solution
  K2 = 0.
  kappa = 0.
  xi = 0.
  yi = 0.
  zi = 0.

  !temperature
  T_gas = 1.d6
  rho_gas = 1.d-20 !cgs
  rho = rho_gas/unit_density

  call init_cooling_solver(ierr)
  call set_abundances

  T = T_gas
  call init_muGamma(rho_gas, T_gas, mu, gamma, pH, pH2)
  call calc_cooling_rate(Q, dlnQ_dlnT, rho, T_gas, T_gas, mu, gamma, K2, kappa)
  tcool = -kboltz*T_gas/((gamma-1.)*mu*atomic_mass_unit*Q*unit_ergg) !code unit
  T_on_u = (gamma-1.)*mu*unit_ergg/Rg

  do imethod = 0,2
     icool_method = imethod
     ui = T/T_on_u
     print *,'#Tin=',T,', rho_cgs=',rho_gas,', tcool_cgs=',tcool,', imethod=',icool_method
     do i = 1,ndt
        dt = tcool*dti(i)
     !print *,'#Tgas=',T,', rho_cgs=',rho_gas,', dt/tcool=',dti(i),', imethod=',icool_method
        call energ_cooling(xi,yi,zi,ui,dudt,rho,dt,T,mu,gamma)
        u = ui+dt*dudt
        Tout = u*T_on_u
        write(*,*) dti(i),T,Tout,dudt
     enddo
  enddo

end subroutine test_solvers

subroutine get_rate

 real :: T_gas, rho_gas, mu, gamma, nH, nH2, nHe, nCO, nH2O, nOH, kappa_gas
 real :: pH, pH2
 real :: T_dust, v_drift, d2g, a, rho_grain, kappa_dust
 real :: JL
 real :: n_gas

 T_gas      = 1500.
 rho_gas    = 1.d-15

 call set_abundances
 call init_muGamma(rho_gas, T_gas, mu, gamma, pH, pH2)
 nH         = pH  *(patm*MPH(eps, Aw))/(mu*mass_proton_cgs*kboltz*T_gas)
 nH2        = pH2 *(patm*MPH(eps, Aw))/(mu*mass_proton_cgs*kboltz*T_gas)

 n_gas      = rho_gas/(mu*mass_proton_cgs)
 nHe        = 1.d-1*n_gas
 nCO        = 1.d-4*n_gas
 nH2O       = 5.d-5*n_gas
 nOH        = 1.d-7*n_gas

 kappa_gas  = 2.d-4

 T_dust     = 1000.
 v_drift    = 1.d6
 d2g        = 1./200.
 a          = 1.d-5
 rho_grain  = 2.
 kappa_dust = calc_kappa_bowen(T_dust)

 JL         = 2.5d-12     ! Value taken from Barstow et al. 1997

 call print_cooling_rates(T_gas, rho_gas, mu, nH, nH2, nHe, nCO, nH2O, nOH, kappa_gas, &
                     T_dust, v_drift, d2g, a, rho_grain, kappa_dust, JL)
end subroutine get_rate


subroutine generate_grid

 real :: logtmin,logtmax,logT,dlogt,T,crate,nH_tot,rho_cgs
 real :: pC, pC2, pC2H, pC2H2, mu, gamma, T_dust, d2g, v_drift
 real :: nH, nH2, nHe, nCO, nH2O, nOH, a, rho_grain, kappa_g, n_gas, rho_gas, kappa_dust, JL
 integer :: i,iunit
 integer, parameter :: nt = 400, iC=3

 logtmax = log10(1.e8)
 logtmin = log10(1.e0)

 call set_abundances()

 open(newunit=iunit,file='new_cooltable.txt',status='replace')
 write(iunit,"(a)") '#   T   \Lambda_E(T) erg s^{-1} cm^3   \Lambda erg s^{-1} cm^{-3}'
 dlogt = (logtmax - logtmin)/real(nt)
 d2g        = 1.d-2
 v_drift    = 0.
 a          = 1.d-5
 rho_grain  = 2.
 kappa_g    = 2.d-4
 JL         = 2.5d-12     ! Value taken from Barstow et al. 1997
 rho_cgs    = 1.d-15

 do i=1,nt
    logT   = logtmin + (i-1)*dlogt
    T      = 10**logT
    T_dust = T
    kappa_dust = calc_kappa_bowen(T)
    nH_tot     = rho_cgs/mass_per_H
    n_gas      = rho_cgs/(mu*mass_proton_cgs)
    call chemical_equilibrium_light(rho_cgs, T, eps(iC), pC, pC2, pC2H, pC2H2, mu, gamma, nH, nH2, nHe, nCO, nH2O, nOH)
    crate = calc_Q(T, rho_cgs, mu, nH, nH2, nHe, nCO, nH2O, nOH, kappa_g, &
                     T_dust, v_drift, d2g, a, rho_grain, kappa_dust, JL)
    !ndens = (rho_cgs/mass_proton_cgs)*5.d0/7.d0
    !print *,rho_cgs, T, mu, gamma, nH, nH2, nHe, nCO, nH2O, nOH, crate
    write(iunit,*) t,crate/nH_tot**2,crate
 enddo
 close(iunit)
end subroutine generate_grid

real function MPH(eps, Aw)

  real, dimension(nElements), intent(inout) :: eps, Aw
  real :: wind_CO_ratio

  wind_CO_ratio = 2.0
  eps(3)        = eps(4) * wind_CO_ratio
  MPH           = atomic_mass_unit*dot_product(Aw,eps)

end function MPH


end module analysis
