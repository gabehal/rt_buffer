#include <cassert>
#include <cmath>
#include "sim_robot.h"

int main() {
    // 1. make a robot that starts at time 0
    double start_time = 0.0;
    SimRobot test_robot(start_time);

    // 2. set its torque_cmd to 0.1
    double tau = 0.1;
    double b = test_robot.friction;
    double J = test_robot.inertia;
    test_robot.torque_cmd= tau;

    // 3. catch it up to 0.00603 seconds
    double elap_time= 0.00603;
    test_robot.catch_up(start_time+ elap_time);

    // 4. work out the exact speed from the formula
    double speed = test_robot.speed;
    double speed_exp=(tau/b)*(1-std::exp(-elap_time/(J/b)));
    double tol= 0.001*speed_exp;
    
    // 5. assert the robot's speed is within 0.1% of the exact one
    assert(std::fabs(speed-speed_exp)<=tol);

    // 6. do that with angle
    double angle_exp = (tau/b) * (elap_time - (J/b) * (1 - std::exp(-elap_time/(J/b))));
    double angle_tol = 0.02 * angle_exp;
    assert(std::fabs(test_robot.angle - angle_exp) <= angle_tol);

    return 0;
}