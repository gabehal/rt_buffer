#pragma once 

// One simulated joint: a wheel on an axle. Physics only, no clocks or threads in here.
struct SimRobot {

    // fixed properties of this joint
    static constexpr double inertia  = 0.01;  // kg*m^2      J: how hard it is to spin up
    static constexpr double friction = 0.05;  // N*m*s/rad   b: drag that grows with speed
    static constexpr double slice = 50e-6;    // computation slice

    // state: the physics updates these every step
    double angle = 0.0;       // rad    where the joint points
    double speed = 0.0;       // rad/s  how fast it is turning

    // inputs: set from outside, felt by the physics until someone changes them
    double torque_cmd = 0.0;  // N*m    motor torque the controller last asked for, held between ticks
    double torque_ext = 0.0;  // N*m    outside push (the shove), set by the script

    double last_time; 

    double shove_time= 0.0; // 0.0
    double shove_duration = 0.0; // 0.5
    double shove_torque = 0.0;

    explicit SimRobot(double start_time) : last_time(start_time) {}
    void step(double dt){

        const double accel = (torque_cmd + torque_ext - friction*speed)/inertia; 
        speed += accel*dt;
        angle += speed*dt; 
    }

    double shove_at(double t) const {
        return (t >= shove_time && t < shove_time + shove_duration) ? shove_torque : 0.0;
    }

    void catch_up(double now){

        const double elapsed_time = now - last_time; // 0.00083
        if (elapsed_time <=0) return;
        const int cycles= static_cast<int>(elapsed_time/slice); // 16
        
        
        for (int i=0; i < cycles; ++i){ //0->15 
            const double t = last_time + i*slice; 
            torque_ext= shove_at(t);
            step(slice); 
        }
        const double remaining= elapsed_time - cycles*slice;
        torque_ext= shove_at(last_time + cycles*slice);
        if (remaining>0) step(remaining);

        last_time = now; 
        
    }

};
